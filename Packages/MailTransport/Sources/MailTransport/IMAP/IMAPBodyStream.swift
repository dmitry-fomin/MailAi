import Foundation
import Core

/// Ошибки стримингового чтения тела.
public enum IMAPBodyStreamError: Error, Sendable, Equatable {
    case noFetchResponse
    case missingLiteralLength
    case truncatedLiteral
    case serverError(status: IMAPResponseStatus, text: String)
}

extension IMAPConnection {

    /// Стримит сырое тело письма по UID с помощью `UID FETCH <uid> BODY.PEEK[]`.
    ///
    /// Возвращает `AsyncThrowingStream<ByteChunk, any Error>`. Байты литерала
    /// отдаются чанками по мере прихода строк из IMAP-канала — мы не копим
    /// всё тело в памяти. Потребитель отвечает за своевременное освобождение
    /// чанков (правило MailAi: тела писем не хранятся на диске, в памяти —
    /// только на время обработки).
    ///
    /// ВАЖНО: используется `BODY.PEEK[]`, чтобы не устанавливать `\Seen`
    /// автоматически. Флаг пометить прочитанным следует отдельной STORE-командой
    /// только после явного действия пользователя.
    ///
    /// Стрим замыкается сразу после tagged-ответа. Ошибки канала и парсинга
    /// пробрасываются как failure.
    public func streamBody(uid: UInt32, section: String = "") -> AsyncThrowingStream<ByteChunk, any Error> {
        AsyncThrowingStream<ByteChunk, any Error> { continuation in
            let task = Task { [self] in
                do {
                    try await runBodyStream(uid: uid, section: section, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Собирает всё тело в память (удобно для тестов и мелких писем). НЕ
    /// использовать для больших вложений — предпочитать `streamBody` +
    /// немедленная обработка чанков.
    public func fetchBody(uid: UInt32, section: String = "") async throws -> [UInt8] {
        var buffer: [UInt8] = []
        for try await chunk in streamBody(uid: uid, section: section) {
            buffer.append(contentsOf: chunk.bytes)
        }
        return buffer
    }

    // MARK: - Internals

    private func runBodyStream(
        uid: UInt32,
        section: String,
        continuation: AsyncThrowingStream<ByteChunk, any Error>.Continuation
    ) async throws {
        let tag = await tagGenerator.next()
        let sectionSpec = "BODY.PEEK[\(section)]"
        let cmd = "UID FETCH \(uid) \(sectionSpec)"
        try await outboundWrite(IMAPLine("\(tag) \(cmd)"))

        var sawFetch = false
        var taggedResult: IMAPTaggedResponse?

        readLoop: while let line = try await iteratorNext() {
            let parsed = IMAPParser.parse(line.raw)
            switch parsed {
            case .tagged(let t) where t.tag == tag:
                taggedResult = t
                break readLoop
            case .tagged, .continuation:
                continue
            case .untagged(let u):
                let parts = u.raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 2, parts[1].uppercased() == "FETCH" else { continue }
                sawFetch = true
                try await streamLiteral(from: u.raw, continuation: continuation)
            }
        }

        guard let final = taggedResult else {
            throw IMAPConnectionError.channelClosed
        }
        guard final.status == .ok else {
            throw IMAPBodyStreamError.serverError(status: final.status, text: final.text)
        }
        if !sawFetch {
            throw IMAPBodyStreamError.noFetchResponse
        }
    }

    /// Парсит первую untagged FETCH-линию и находит `{length}`. Затем читает
    /// из inbound-потока линии до исчерпания длины, восстанавливая CRLF между
    /// ними. Каждая линия отдаётся отдельным `ByteChunk`.
    private func streamLiteral(
        from firstLine: String,
        continuation: AsyncThrowingStream<ByteChunk, any Error>.Continuation
    ) async throws {
        // Ищем {NNN} в строке FETCH.
        guard let openBrace = firstLine.lastIndex(of: "{"),
              let closeBrace = firstLine[openBrace...].firstIndex(of: "}") else {
            // Сервер мог вернуть тело в кавычках (короткие письма). Попробуем
            // вытащить quoted-строку после BODY[…].
            if let quotedStart = firstLine.firstIndex(of: "\""),
               let quotedEnd = firstLine[firstLine.index(after: quotedStart)...].lastIndex(of: "\"") {
                let inner = firstLine[firstLine.index(after: quotedStart)..<quotedEnd]
                let bytes = Array(inner.utf8)
                if !bytes.isEmpty {
                    continuation.yield(ByteChunk(bytes: bytes))
                }
                return
            }
            throw IMAPBodyStreamError.missingLiteralLength
        }
        let numStr = firstLine[firstLine.index(after: openBrace)..<closeBrace]
        guard let total = Int(numStr) else {
            throw IMAPBodyStreamError.missingLiteralLength
        }

        var remaining = total
        while remaining > 0 {
            guard let line = try await iteratorNext() else {
                throw IMAPBodyStreamError.truncatedLiteral
            }
            // Line-based decoder снял CRLF. Длина линии в байтах UTF-8 + CRLF
            // (2 байта) — столько байт «израсходовано» из литерала.
            let lineBytes = Array(line.raw.utf8)
            let consumed = lineBytes.count + 2  // + CRLF
            if consumed <= remaining {
                // Полноценная линия внутри литерала: восстанавливаем CRLF,
                // который снял line-based decoder (он был частью тела письма).
                var chunk = lineBytes
                chunk.append(0x0D); chunk.append(0x0A)
                continuation.yield(ByteChunk(bytes: chunk))
                remaining -= consumed
            } else {
                // Линия длиннее оставшегося литерала: берём префикс, хвост
                // (с возможным `)`) игнорируем.
                let prefix = Array(lineBytes.prefix(remaining))
                continuation.yield(ByteChunk(bytes: prefix))
                remaining = 0
            }
        }
        // После литерала должен идти закрывающий `)` (возможно на следующей
        // строке). Мы не читаем её здесь — основной цикл в runBodyStream
        // дочитает tagged.
    }

    // MARK: - Reflection-free channel access
    //
    // IMAPConnection хранит outbound/iterator приватно. Ниже — минимальные
    // мостики, чтобы streamBody мог использовать их без расширения публичного
    // API. Реализованы как extension-методы файла.

    private func outboundWrite(_ line: IMAPLine) async throws {
        try await IMAPConnectionBridge.write(self, line: line)
    }

    private func iteratorNext() async throws -> IMAPLine? {
        try await IMAPConnectionBridge.next(self)
    }
}

/// Вспомогательный мост к приватным полям `IMAPConnection`. Имплементация
/// через `@_spi`-подобный внутренний API: добавлены internal-методы в
/// самом классе (см. ниже extension с internal-видимостью).
enum IMAPConnectionBridge {
    static func write(_ conn: IMAPConnection, line: IMAPLine) async throws {
        try await conn._writeOutbound(line)
    }
    static func next(_ conn: IMAPConnection) async throws -> IMAPLine? {
        try await conn._readNext()
    }
}
