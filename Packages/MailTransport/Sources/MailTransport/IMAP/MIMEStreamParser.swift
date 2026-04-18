import Foundation

/// Событие стримингового MIME-парсера.
public enum MIMEStreamEvent: Sendable {
    /// Начало части. `path` — индексы вложенности (0-based), пустой — корень.
    case partStart(path: [Int], headers: [MIMEHeader])
    /// Очередной чанк декодированного тела (после CTE-декодирования).
    case bodyChunk(path: [Int], bytes: [UInt8])
    /// Конец части.
    case partEnd(path: [Int])
}

public struct MIMEHeader: Sendable, Equatable {
    public let name: String
    public let value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Стриминговый MIME-парсер. Состояние — изолированный `class`, вызывающая
/// сторона должна использовать экземпляр из одного Task (не Sendable).
///
/// Архитектура: работает построчно (MIME-boundaries всегда на отдельных
/// CRLF-линиях). Входной поток — чанки байтов; парсер аккумулирует текущую
/// незавершённую линию и обрабатывает каждую завершённую линию в контексте
/// текущей части. Для multipart создаётся стек вложенности.
///
/// Тело НЕ накапливается целиком: декодированные байты текущей части
/// отдаются через callback по мере поступления. Промежуточный буфер линии
/// ограничен одной строкой (в типичных письмах < 1 KB после unfolding).
public final class MIMEStreamParser {
    public typealias EventHandler = (MIMEStreamEvent) -> Void

    private enum State {
        case headers
        case body
        case done
    }

    private final class Frame {
        let path: [Int]
        let boundary: String?        // наш boundary (для multipart)
        let parentBoundary: String?  // boundary родителя (для singlepart — чтобы поймать разделитель)
        var state: State = .headers
        var headerBuffer: [UInt8] = []
        var headers: [MIMEHeader] = []
        var decoder: any MIMEStreamingDecoder = MIMEIdentityDecoder()
        var isMultipart: Bool = false
        var childIndex: Int = 0
        var seenFirstBoundary: Bool = false

        init(path: [Int], parentBoundary: String?) {
            self.path = path
            self.parentBoundary = parentBoundary
            self.boundary = nil
        }

        init(path: [Int], parentBoundary: String?, boundary: String?) {
            self.path = path
            self.parentBoundary = parentBoundary
            self.boundary = boundary
        }
    }

    private var stack: [Frame] = []
    private var lineBuf: [UInt8] = []
    private var pendingCR = false
    private let onEvent: EventHandler
    private var finished = false

    public init(onEvent: @escaping EventHandler) {
        self.onEvent = onEvent
        self.stack.append(Frame(path: [], parentBoundary: nil))
    }

    /// Подать очередной чанк в парсер.
    public func feed(_ bytes: [UInt8]) {
        guard !finished else { return }
        for b in bytes {
            if b == UInt8(ascii: "\n") {
                processLine(lineBuf)
                lineBuf.removeAll(keepingCapacity: true)
                pendingCR = false
            } else if b == UInt8(ascii: "\r") {
                pendingCR = true
                // CR держим до следующего символа — если за ним LF, это EOL;
                // иначе добавим CR в буфер.
            } else {
                if pendingCR {
                    lineBuf.append(UInt8(ascii: "\r"))
                    pendingCR = false
                }
                lineBuf.append(b)
            }
        }
    }

    /// Завершение потока. Выдаёт оставшиеся события и закрывает открытые части.
    public func finish() {
        guard !finished else { return }
        if pendingCR { lineBuf.append(UInt8(ascii: "\r")) }
        if !lineBuf.isEmpty {
            processLine(lineBuf)
            lineBuf.removeAll()
        }
        // Закрываем все оставшиеся открытые части.
        while !stack.isEmpty {
            let frame = stack.removeLast()
            if frame.state == .body && !frame.isMultipart {
                let tail = frame.decoder.finish()
                if !tail.isEmpty {
                    onEvent(.bodyChunk(path: frame.path, bytes: tail))
                }
            }
            if frame.state != .headers || !frame.headers.isEmpty {
                onEvent(.partEnd(path: frame.path))
            }
        }
        finished = true
    }

    // MARK: - Internals

    private func processLine(_ line: [UInt8]) {
        guard let frame = stack.last else { return }

        // Проверка на boundary-линию в любом состоянии (кроме самых верхних headers).
        if let boundary = enclosingBoundary(), isBoundaryLine(line, boundary: boundary) {
            let closing = isClosingBoundary(line, boundary: boundary)
            handleBoundary(closing: closing)
            return
        }

        switch frame.state {
        case .headers:
            handleHeaderLine(line, in: frame)
        case .body:
            if !frame.isMultipart {
                // Декодируем линию + CRLF (восстанавливаем разделитель).
                var chunk = frame.decoder.feed(line)
                // Приклеиваем CRLF между линиями, кроме первой; чтобы это
                // корректно работало, добавляем CRLF после каждой линии — так
                // декодированное тело сохраняет оригинальные переносы.
                let crlf: [UInt8] = [0x0D, 0x0A]
                chunk.append(contentsOf: frame.decoder.feed(crlf))
                if !chunk.isEmpty {
                    onEvent(.bodyChunk(path: frame.path, bytes: chunk))
                }
            }
            // Для multipart в body игнорируем preamble до первого boundary.
        case .done:
            break
        }
    }

    private func handleHeaderLine(_ line: [UInt8], in frame: Frame) {
        if line.isEmpty {
            // Конец заголовков. Парсим их и решаем — multipart или нет.
            let raw = String(decoding: frame.headerBuffer, as: UTF8.self)
            let parsed = MIMEHeaderUnfold.parse(raw)
            frame.headers = parsed.map { MIMEHeader(name: $0.name, value: $0.value) }

            let contentType = MIMEHeaderUnfold.find(parsed, name: "Content-Type") ?? "text/plain"
            let (primary, params) = MIMEHeaderUnfold.parseStructuredValue(contentType)
            let cte = MIMEHeaderUnfold.find(parsed, name: "Content-Transfer-Encoding")

            onEvent(.partStart(path: frame.path, headers: frame.headers))

            if primary.hasPrefix("multipart/"), let boundary = params["boundary"] {
                // Подменяем текущую фрейм-запись: для multipart boundary
                // живёт в самом фрейме. state ставим в .body ДО подмены,
                // чтобы новый frame унаследовал его.
                frame.state = .body
                frame.isMultipart = true
                stack[stack.count - 1] = replaceBoundary(frame, boundary: boundary)
            } else {
                frame.decoder = MIMETransferEncoding.decoder(for: cte)
                frame.state = .body
            }
            return
        }
        frame.headerBuffer.append(contentsOf: line)
        frame.headerBuffer.append(0x0D)
        frame.headerBuffer.append(0x0A)
    }

    private func replaceBoundary(_ old: Frame, boundary: String) -> Frame {
        let new = Frame(path: old.path, parentBoundary: old.parentBoundary, boundary: boundary)
        new.state = old.state
        new.headerBuffer = old.headerBuffer
        new.headers = old.headers
        new.isMultipart = true
        return new
    }

    /// Ближайший активный boundary: либо у текущего multipart-фрейма, либо у родителя.
    private func enclosingBoundary() -> String? {
        for frame in stack.reversed() {
            if let b = frame.boundary { return b }
            if let b = frame.parentBoundary { return b }
        }
        return nil
    }

    private func isBoundaryLine(_ line: [UInt8], boundary: String) -> Bool {
        let prefix: [UInt8] = [UInt8(ascii: "-"), UInt8(ascii: "-")]
        let bBytes = Array(boundary.utf8)
        guard line.count >= prefix.count + bBytes.count else { return false }
        return Array(line[0..<2]) == prefix && Array(line[2..<2 + bBytes.count]) == bBytes
    }

    private func isClosingBoundary(_ line: [UInt8], boundary: String) -> Bool {
        let bBytes = Array(boundary.utf8)
        let expectedLen = 2 + bBytes.count + 2
        guard line.count >= expectedLen else { return false }
        return line[2 + bBytes.count] == UInt8(ascii: "-")
            && line[2 + bBytes.count + 1] == UInt8(ascii: "-")
    }

    private func handleBoundary(closing: Bool) {
        // Если текущий фрейм — singlepart, это значит закончилась его body-часть.
        // Закрываем все фреймы до ближайшего multipart, чей boundary совпал.
        guard let multipartIndex = stack.lastIndex(where: { $0.boundary != nil }) else {
            return
        }
        // Закрываем все потомков выше multipart-фрейма.
        while stack.count - 1 > multipartIndex {
            let leaf = stack.removeLast()
            if !leaf.isMultipart {
                let tail = leaf.decoder.finish()
                if !tail.isEmpty { onEvent(.bodyChunk(path: leaf.path, bytes: tail)) }
            }
            onEvent(.partEnd(path: leaf.path))
        }
        let multipart = stack[multipartIndex]
        if closing {
            // Конец multipart: закрываем сам multipart-фрейм.
            stack.removeLast()
            onEvent(.partEnd(path: multipart.path))
            return
        }
        // Открываем новую дочернюю часть.
        multipart.seenFirstBoundary = true
        let childPath = multipart.path + [multipart.childIndex]
        multipart.childIndex += 1
        let child = Frame(path: childPath, parentBoundary: multipart.boundary)
        stack.append(child)
    }
}
