import Foundation
import Core
import Storage
import Secrets
import MailTransport
import NIOCore
import NIOPosix

// Mail-4: smoke операций над письмами.
// Fake IMAP-сервер запоминает полученные команды в NIOLockedValueBox;
// после вызова LiveAccountDataProvider.delete/setFlagged/archive проверяем,
// что провайдер отправил ожидаемые IMAP-команды.

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(msg)\n".utf8))
    exit(1)
}

func check(_ label: String, _ cond: Bool) {
    guard cond else { die(label) }
    print("✓ \(label)")
}

// MARK: - Command log

final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    func append(_ cmd: String) {
        lock.lock(); defer { lock.unlock() }
        commands.append(cmd)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }

    func contains(_ fragment: String) -> Bool {
        snapshot().contains { $0.uppercased().contains(fragment.uppercased()) }
    }
}

let log = CommandLog()

// MARK: - Fake server with state

final class ActionsHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = IMAPLine
    typealias OutboundOut = IMAPLine

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(IMAPLine("* OK actions-imap")), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data).raw
        log.append(line)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count >= 2 else { return }
        let tag = parts[0]
        let cmd = parts[1].uppercased()

        if cmd.hasPrefix("LOGIN") {
            write(context, "\(tag) OK LOGIN completed")
        } else if cmd.hasPrefix("CAPABILITY") {
            // Сообщаем про MOVE, чтобы провайдер пошёл по UID MOVE-пути.
            write(context, "* CAPABILITY IMAP4rev1 UIDPLUS MOVE SPECIAL-USE")
            write(context, "\(tag) OK CAPABILITY")
        } else if cmd.hasPrefix("LIST") {
            write(context, "* LIST (\\HasNoChildren) \"/\" \"INBOX\"")
            write(context, "* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"")
            write(context, "* LIST (\\HasNoChildren \\Trash) \"/\" \"Trash\"")
            write(context, "\(tag) OK LIST completed")
        } else if cmd.hasPrefix("SELECT") {
            write(context, "* 1 EXISTS")
            write(context, "* OK [UIDVALIDITY 3] ok")
            write(context, "* OK [UIDNEXT 2] ok")
            write(context, "* FLAGS (\\Seen)")
            write(context, "\(tag) OK [READ-WRITE] SELECT completed")
        } else if cmd.hasPrefix("UID FETCH") && cmd.contains("BODY.PEEK[]") {
            write(context, "\(tag) OK FETCH completed")
        } else if cmd.hasPrefix("UID FETCH") {
            let env = "ENVELOPE (\"Tue, 17 Apr 2026 10:30:42 +0300\" \"actions test\" ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Bob\" NIL \"bob\" \"example.com\")) NIL NIL NIL \"<a-1@example.com>\")"
            let bs = "BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 64 2)"
            write(context, "* 1 FETCH (UID 1 FLAGS (\\Seen) INTERNALDATE \"17-Apr-2026 10:30:42 +0300\" RFC822.SIZE 64 \(env) \(bs))")
            write(context, "\(tag) OK FETCH completed")
        } else if cmd.hasPrefix("UID STORE") {
            write(context, "\(tag) OK STORE completed")
        } else if cmd.hasPrefix("UID COPY") {
            write(context, "\(tag) OK COPY completed")
        } else if cmd.hasPrefix("UID MOVE") {
            write(context, "\(tag) OK MOVE completed")
        } else if cmd.hasPrefix("EXPUNGE") {
            write(context, "\(tag) OK EXPUNGE completed")
        } else if cmd.hasPrefix("LOGOUT") {
            write(context, "* BYE")
            write(context, "\(tag) OK LOGOUT")
        } else {
            write(context, "\(tag) OK")
        }
        context.flush()
    }

    private func write(_ ctx: ChannelHandlerContext, _ line: String) {
        ctx.write(wrapOutboundOut(IMAPLine(line)), promise: nil)
    }
}

actor ActionsServer {
    let port: Int
    private let channel: any Channel

    static func start(on group: MultiThreadedEventLoopGroup) async throws -> ActionsServer {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let sync = ch.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(ActionsHandler())
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return ActionsServer(port: ch.localAddress!.port!, channel: ch)
    }

    private init(port: Int, channel: any Channel) {
        self.port = port
        self.channel = channel
    }

    func stop() async throws { try await channel.close() }
}

// MARK: - Runner

@main
enum ActionsSmokeRunner {
    static func main() async throws { try await runActions() }
}

func runActions() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailai-actions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = try GRDBMetadataStore(url: tmp.appendingPathComponent("metadata.sqlite"))

    let group = MultiThreadedEventLoopGroup.singleton
    let server = try await ActionsServer.start(on: group)
    defer { Task { try? await server.stop() } }

    let account = Account(
        id: Account.ID("actions-smoke"),
        email: "bob@example.com",
        displayName: nil,
        kind: .imap,
        host: "127.0.0.1",
        port: UInt16(server.port),
        security: .none,
        username: "bob"
    )
    let secrets = InMemorySecretsStore()
    try await secrets.setPassword("secret", forAccount: account.id)

    let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)
    let provider = LiveAccountDataProvider(
        account: account,
        store: store,
        secrets: secrets,
        endpoint: endpoint
    )

    // Готовим store: mailboxes() → account+mailboxes, затем messages() → message row.
    _ = try await provider.mailboxes()
    var messages: [Message] = []
    for try await batch in provider.messages(in: Mailbox.ID("INBOX"), page: .init(offset: 0, limit: 10)) {
        messages = batch
    }
    guard let msg = messages.first else { die("provider не вернул ни одного письма") }

    // 1) setFlagged(true)
    try await provider.setFlagged(true, messageID: msg.id)
    check("UID STORE +FLAGS (\\Flagged) отправлен",
          log.contains("UID STORE 1 +FLAGS (\\Flagged)"))

    // 2) archive → UID MOVE в Archive (CAPABILITY заявил MOVE)
    try await provider.archive(messageID: msg.id)
    check("UID MOVE в Archive отправлен",
          log.contains("UID MOVE 1 \"Archive\""))

    // 3) delete — нужен новый message (после archive удалили из store).
    //    Пересинхронизируем: mailboxes → messages → delete.
    _ = try await provider.mailboxes()
    for try await batch in provider.messages(in: Mailbox.ID("INBOX"), page: .init(offset: 0, limit: 10)) {
        messages = batch
    }
    guard let msg2 = messages.first else { die("после ресинка provider не вернул письмо") }
    try await provider.delete(messageID: msg2.id)
    check("UID STORE +FLAGS (\\Deleted) при delete",
          log.contains("+FLAGS (\\Deleted)"))
    check("EXPUNGE после STORE \\Deleted",
          log.contains("EXPUNGE"))

    print("✅ ActionsSmoke OK")
}
