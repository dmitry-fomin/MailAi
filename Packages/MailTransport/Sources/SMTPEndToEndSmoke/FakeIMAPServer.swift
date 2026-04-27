// SMTP-6: in-process fake IMAP server для проверки APPEND-литерала.
//
// Минимальная RFC 3501-ish реализация: greeting → CAPABILITY → LOGIN →
// LIST → APPEND (две фазы: header + literal) → LOGOUT.
//
// Литерал передаётся клиентом в виде нескольких CRLF-разделённых строк
// (наш frame-encoder добавляет CRLF между записями). Сервер собирает их,
// пока суммарная длина (utf8 + 2 байта на CRLF между строками) не сравняется
// с заявленным literalOctets.

import Foundation
import NIOCore
import NIOPosix
import MailTransport

/// Снимок последнего IMAP APPEND для проверок.
struct FakeIMAPCapture: Sendable {
    let mailbox: String
    let flags: [String]
    let literal: String
}

actor FakeIMAPCaptureStore {
    private(set) var lastAppend: FakeIMAPCapture?
    private(set) var loginSeen = false
    private(set) var listSeen = false
    private(set) var logoutSeen = false

    func setAppend(_ capture: FakeIMAPCapture) { self.lastAppend = capture }
    func markLogin() { loginSeen = true }
    func markList() { listSeen = true }
    func markLogout() { logoutSeen = true }
}

final class FakeIMAPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = IMAPLine
    typealias OutboundOut = IMAPLine

    private enum Phase {
        case ready
        case awaitingLiteral(tag: String, mailbox: String, flags: [String], remaining: Int, accumulated: [String])
    }

    private let store: FakeIMAPCaptureStore
    private var phase: Phase = .ready

    init(store: FakeIMAPCaptureStore) {
        self.store = store
    }

    func channelActive(context: ChannelHandlerContext) {
        write(context, "* OK [CAPABILITY IMAP4rev1] fake-imap ready")
        context.flush()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data).raw

        if case .awaitingLiteral(let tag, let mailbox, let flags, let remaining, var accumulated) = phase {
            // Приходит часть литерала. Учитываем utf8 + 2 (CRLF разделитель,
            // вставленный фрейм-кодеком клиента между строками).
            let chunkLen = line.utf8.count + 2 // +2 за CRLF
            accumulated.append(line)
            let newRemaining = remaining - chunkLen
            if newRemaining <= 0 {
                // Литерал получен (с возможным небольшим overshoot из-за
                // финального CRLF — это корректно для RFC 3501 literal API,
                // но мы не валидируем точное совпадение октетов в smoke).
                let body = accumulated.joined(separator: "\r\n")
                let capture = FakeIMAPCapture(
                    mailbox: mailbox,
                    flags: flags,
                    literal: body
                )
                let store = self.store
                Task { await store.setAppend(capture) }
                write(context, "\(tag) OK APPEND completed")
                context.flush()
                phase = .ready
            } else {
                phase = .awaitingLiteral(
                    tag: tag,
                    mailbox: mailbox,
                    flags: flags,
                    remaining: newRemaining,
                    accumulated: accumulated
                )
            }
            return
        }

        // Парсим обычную команду: "<tag> CMD args..."
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count >= 2 else {
            write(context, "* BAD malformed command")
            context.flush()
            return
        }
        let tag = parts[0]
        let rest = parts[1]
        let upper = rest.uppercased()

        if upper.hasPrefix("CAPABILITY") {
            write(context, "* CAPABILITY IMAP4rev1 LITERAL+ AUTH=PLAIN")
            write(context, "\(tag) OK CAPABILITY completed")
            context.flush()
            return
        }
        if upper.hasPrefix("LOGIN") {
            let store = self.store
            Task { await store.markLogin() }
            write(context, "\(tag) OK LOGIN completed")
            context.flush()
            return
        }
        if upper.hasPrefix("LIST") {
            let store = self.store
            Task { await store.markList() }
            // Минимум: INBOX и Drafts со SPECIAL-USE \Drafts
            write(context, #"* LIST () "/" "INBOX""#)
            write(context, #"* LIST (\Drafts) "/" "Drafts""#)
            write(context, "\(tag) OK LIST completed")
            context.flush()
            return
        }
        if upper.hasPrefix("SELECT") {
            write(context, "* 0 EXISTS")
            write(context, "* 0 RECENT")
            write(context, "* OK [UIDVALIDITY 1] UIDs valid")
            write(context, "* OK [UIDNEXT 1] Predicted next UID")
            write(context, "\(tag) OK [READ-WRITE] SELECT completed")
            context.flush()
            return
        }
        if upper.hasPrefix("APPEND") {
            // Парсим: APPEND "Drafts" (\Draft) {N}
            guard let (mailbox, flags, literalLen) = Self.parseAppendHeader(rest) else {
                write(context, "\(tag) BAD malformed APPEND")
                context.flush()
                return
            }
            phase = .awaitingLiteral(
                tag: tag,
                mailbox: mailbox,
                flags: flags,
                remaining: literalLen,
                accumulated: []
            )
            write(context, "+ Ready for literal data")
            context.flush()
            return
        }
        if upper.hasPrefix("LOGOUT") {
            let store = self.store
            Task { await store.markLogout() }
            write(context, "* BYE fake-imap closing")
            write(context, "\(tag) OK LOGOUT completed")
            context.flush()
            context.close(promise: nil)
            return
        }
        // Прочие команды — отвечаем OK.
        write(context, "\(tag) OK")
        context.flush()
    }

    private func write(_ context: ChannelHandlerContext, _ line: String) {
        context.write(wrapOutboundOut(IMAPLine(line)), promise: nil)
    }

    /// Парсит APPEND-заголовок: возвращает mailbox, flags, длину литерала.
    static func parseAppendHeader(_ rest: String) -> (String, [String], Int)? {
        // rest = `APPEND "Drafts" (\Draft) {123}` или без flags.
        guard let braceOpen = rest.lastIndex(of: "{"),
              let braceClose = rest.lastIndex(of: "}"),
              braceOpen < braceClose else { return nil }
        let lenStr = rest[rest.index(after: braceOpen)..<braceClose]
        guard let len = Int(lenStr) else { return nil }

        // Mailbox: первый токен в кавычках после APPEND.
        guard let firstQuote = rest.firstIndex(of: "\"") else { return nil }
        let afterFirst = rest.index(after: firstQuote)
        guard let secondQuote = rest[afterFirst...].firstIndex(of: "\"") else { return nil }
        let mailbox = String(rest[afterFirst..<secondQuote])

        // Flags: содержимое (...) если есть.
        var flags: [String] = []
        if let parenOpen = rest.firstIndex(of: "("),
           let parenClose = rest.firstIndex(of: ")"),
           parenOpen < parenClose,
           parenOpen > secondQuote {
            let flagsStr = rest[rest.index(after: parenOpen)..<parenClose]
            flags = flagsStr.split(separator: " ").map(String.init)
        }
        return (mailbox, flags, len)
    }
}

actor FakeIMAPServer {
    nonisolated let port: Int
    nonisolated let captureStore: FakeIMAPCaptureStore
    private let channel: any Channel

    static func start(on group: MultiThreadedEventLoopGroup) async throws -> FakeIMAPServer {
        let store = FakeIMAPCaptureStore()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(FakeIMAPHandler(store: store))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = ch.localAddress?.port else {
            throw FakeServerError.noPort
        }
        return FakeIMAPServer(port: port, channel: ch, captureStore: store)
    }

    private init(port: Int, channel: any Channel, captureStore: FakeIMAPCaptureStore) {
        self.port = port
        self.channel = channel
        self.captureStore = captureStore
    }

    func stop() async throws {
        try await channel.close()
    }
}
