import Foundation
import Core
import Storage
import Secrets
import MailTransport
import NIOCore
import NIOPosix

// Live-6: end-to-end smoke LiveAccountDataProvider.
//
// Сценарий:
//   1) fake IMAP server с LIST (INBOX + Sent + Trash) / SELECT / UID FETCH
//      headers / UID FETCH BODY[] (тело с уникальным токеном).
//   2) InMemorySecretsStore с захардкоженным паролем для test-account.
//   3) GRDBMetadataStore на диске (tmp dir).
//   4) provider.mailboxes() → ожидаем 3 папки с правильными Role.
//   5) provider.messages(in: INBOX, …) → через AsyncStream получаем Message
//      с валидными UID (B6 syncHeaders записал в store).
//   6) provider.body(for: msgID) → стрим чанков, собираем в строку,
//      проверяем токен.
//   7) После всего — grep sqlite/wal/shm на токен (invariant CLAUDE.md).

let LIVE_TOKEN = "LIVE_FLOW_TOKEN_9Q2K"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(msg)\n".utf8))
    exit(1)
}

func check(_ label: String, _ cond: Bool) {
    guard cond else { die(label) }
    print("✓ \(label)")
}

// MARK: - Fake IMAP server

final class LiveHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = IMAPLine
    typealias OutboundOut = IMAPLine

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(IMAPLine("* OK live-imap")), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data).raw
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count >= 2 else { return }
        let tag = parts[0]
        let cmd = parts[1].uppercased()

        if cmd.hasPrefix("LOGIN") {
            write(context, "\(tag) OK LOGIN completed")
        } else if cmd.hasPrefix("CAPABILITY") {
            write(context, "* CAPABILITY IMAP4rev1 UIDPLUS SPECIAL-USE")
            write(context, "\(tag) OK CAPABILITY")
        } else if cmd.hasPrefix("LIST") {
            write(context, "* LIST (\\HasNoChildren) \"/\" \"INBOX\"")
            write(context, "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"")
            write(context, "* LIST (\\HasNoChildren \\Trash) \"/\" \"Trash\"")
            write(context, "\(tag) OK LIST completed")
        } else if cmd.hasPrefix("SELECT") {
            write(context, "* 1 EXISTS")
            write(context, "* OK [UIDVALIDITY 7] ok")
            write(context, "* OK [UIDNEXT 2] ok")
            write(context, "* FLAGS (\\Seen)")
            write(context, "\(tag) OK [READ-WRITE] SELECT completed")
        } else if cmd.hasPrefix("UID FETCH") && cmd.contains("BODY.PEEK[]") {
            let body = """
            From: alice@example.com\r
            Subject: live test\r
            Message-ID: <live-1@example.com>\r
            \r
            Body contains \(LIVE_TOKEN) canary.\r
            """
            let bytes = Array(body.utf8).count
            write(context, "* 1 FETCH (UID 1 BODY[] {\(bytes)}")
            for part in body.components(separatedBy: "\r\n") { write(context, part) }
            write(context, ")")
            write(context, "\(tag) OK FETCH completed")
        } else if cmd.hasPrefix("UID FETCH") {
            let env = "ENVELOPE (\"Tue, 17 Apr 2026 10:30:42 +0300\" \"live test\" ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Bob\" NIL \"bob\" \"example.com\")) NIL NIL NIL \"<live-1@example.com>\")"
            let bs = "BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 128 3)"
            write(context, "* 1 FETCH (UID 1 FLAGS (\\Seen) INTERNALDATE \"17-Apr-2026 10:30:42 +0300\" RFC822.SIZE 128 \(env) \(bs))")
            write(context, "\(tag) OK FETCH completed")
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

actor LiveServer {
    let port: Int
    private let channel: any Channel

    static func start(on group: MultiThreadedEventLoopGroup) async throws -> LiveServer {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let sync = ch.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(LiveHandler())
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return LiveServer(port: ch.localAddress!.port!, channel: ch)
    }

    private init(port: Int, channel: any Channel) {
        self.port = port
        self.channel = channel
    }

    func stop() async throws { try await channel.close() }
}

// MARK: - Runner

@main
enum LiveFlowSmokeRunner {
    static func main() async throws { try await runLive() }
}

func runLive() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailai-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let dbURL = tmp.appendingPathComponent("metadata.sqlite")
    let store = try GRDBMetadataStore(url: dbURL)

    let group = MultiThreadedEventLoopGroup.singleton
    let server = try await LiveServer.start(on: group)
    defer { Task { try? await server.stop() } }

    let account = Account(
        id: Account.ID("live-flow-account"),
        email: "bob@example.com",
        displayName: nil,
        kind: .imap,
        host: "127.0.0.1",
        port: UInt16(server.port),
        security: .none,
        username: "bob"
    )
    try await store.upsert(account)

    let secrets = InMemorySecretsStore()
    try await secrets.setPassword("secret", forAccount: account.id)

    let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)
    let provider = LiveAccountDataProvider(
        account: account,
        store: store,
        secrets: secrets,
        endpoint: endpoint
    )

    // 1) mailboxes()
    let mailboxes = try await provider.mailboxes()
    check("mailboxes() вернул 3 папки", mailboxes.count == 3)
    let inbox = mailboxes.first { $0.role == .inbox }
    check("есть INBOX с role=.inbox", inbox != nil)
    check("есть Sent с role=.sent", mailboxes.contains { $0.role == .sent })
    check("есть Trash с role=.trash", mailboxes.contains { $0.role == .trash })
    guard let inbox else { die("INBOX не найден") }

    // 2) messages(in:)
    var receivedBatches = 0
    var allMessages: [Message] = []
    for try await batch in provider.messages(in: inbox.id, page: .init(offset: 0, limit: 10)) {
        receivedBatches += 1
        allMessages = batch
    }
    check("messages() stream выдал >= 1 batch", receivedBatches >= 1)
    check("messages() итоговый batch содержит >= 1 message", !allMessages.isEmpty)
    guard let message = allMessages.first else { die("нет messages") }
    check("message.uid == 1", message.uid == 1)

    // 3) body(for:)
    var bodyBytes: [UInt8] = []
    for try await chunk in provider.body(for: message.id) {
        bodyBytes.append(contentsOf: chunk.bytes)
    }
    let bodyStr = String(bytes: bodyBytes, encoding: .utf8) ?? ""
    check("body содержит LIVE_TOKEN", bodyStr.contains(LIVE_TOKEN))
    bodyBytes = []  // освобождаем

    // Даём WAL зафлашиться (read tx).
    _ = try await store.messages(in: inbox.id, page: .init(offset: 0, limit: 10))

    // 4) invariant: токена нет на диске.
    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    let tokenBytes = Data(LIVE_TOKEN.utf8)
    var found: [String] = []
    for f in files {
        let data = try Data(contentsOf: f)
        if data.range(of: tokenBytes) != nil { found.append(f.lastPathComponent) }
    }
    check("LIVE_TOKEN отсутствует в sqlite/wal/shm (\(files.count) файл(ов))", found.isEmpty)

    print("✅ LiveFlowSmoke OK")
}
