import Foundation
import Core
import Storage
import MailTransport
import NIOCore
import NIOPosix

// C5: интеграционный smoke end-to-end + memory.
//
// Сценарий:
//   1) Поднимаем локальный fake-IMAP сервер с одним письмом.
//   2) Через IMAPConnection: LOGIN → SELECT INBOX → UID FETCH headers → UID
//      FETCH BODY[]. Синхронизируем метаданные в GRDBMetadataStore (реальный
//      sqlite-файл во временной директории).
//   3) Тело содержит уникальный токен `INTEG_SECRET_TOKEN_A7F3`. Проверяем,
//      что токен достижим в памяти после чтения.
//   4) «Закрываем окно»: обнуляем локальные буферы, синхронизируем БД.
//   5) Инвариант памяти: после закрытия grep по sqlite-файлу и WAL
//      не находит ни единого вхождения токена. На диск тела не уходят.
//
// В CLT-only окружении XCTMemoryMetric недоступен; полноценный memory-профиль
// остаётся за Instruments. Этот smoke проверяет самый жёсткий инвариант:
// MessageBody не попадает в Storage.

let SECRET_TOKEN = "INTEG_SECRET_TOKEN_A7F3"
let ACCOUNT_ID_RAW = "integ-smoke-account"
let MAILBOX_ID_RAW = "integ-inbox"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(msg)\n".utf8))
    exit(1)
}

func check(_ label: String, _ cond: Bool) {
    guard cond else { die(label) }
    print("✓ \(label)")
}

// MARK: - Fake IMAP server

final class IntegHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = IMAPLine
    typealias OutboundOut = IMAPLine

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(IMAPLine("* OK integ-imap")), promise: nil)
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
            write(context, "* CAPABILITY IMAP4rev1 UIDPLUS")
            write(context, "\(tag) OK CAPABILITY")
        } else if cmd.hasPrefix("LIST") {
            write(context, "* LIST (\\HasNoChildren) \"/\" \"INBOX\"")
            write(context, "\(tag) OK LIST completed")
        } else if cmd.hasPrefix("SELECT INBOX") || cmd.hasPrefix("SELECT \"INBOX\"") {
            write(context, "* 1 EXISTS")
            write(context, "* OK [UIDVALIDITY 42] ok")
            write(context, "* OK [UIDNEXT 2] ok")
            write(context, "* FLAGS (\\Seen)")
            write(context, "\(tag) OK [READ-ONLY] SELECT completed")
        } else if cmd.hasPrefix("UID FETCH") && cmd.contains("BODY.PEEK[]") {
            let body = """
            From: alice@example.com\r
            To: bob@example.com\r
            Subject: integ test\r
            Message-ID: <integ-1@example.com>\r
            \r
            Hello, this email body contains \(SECRET_TOKEN) as a canary.\r
            End of body.\r
            """
            let bytes = Array(body.utf8).count
            write(context, "* 1 FETCH (UID 1 BODY[] {\(bytes)}")
            // Серверный поток использует line-framing — тело отдаём построчно.
            for part in body.components(separatedBy: "\r\n") {
                write(context, part)
            }
            write(context, ")")
            write(context, "\(tag) OK FETCH completed")
        } else if cmd.hasPrefix("UID FETCH") {
            let envelope = "ENVELOPE (\"Tue, 17 Apr 2026 10:30:42 +0300\" \"integ test\" ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Bob\" NIL \"bob\" \"example.com\")) NIL NIL NIL \"<integ-1@example.com>\")"
            let bs = "BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 128 3)"
            write(context, "* 1 FETCH (UID 1 FLAGS (\\Seen) INTERNALDATE \"17-Apr-2026 10:30:42 +0300\" RFC822.SIZE 128 \(envelope) \(bs))")
            write(context, "\(tag) OK FETCH completed")
        } else if cmd.hasPrefix("LOGOUT") {
            write(context, "* BYE")
            write(context, "\(tag) OK LOGOUT")
        } else {
            write(context, "\(tag) OK")
        }
        context.flush()
    }

    private func write(_ context: ChannelHandlerContext, _ line: String) {
        context.write(wrapOutboundOut(IMAPLine(line)), promise: nil)
    }
}

actor IntegServer {
    let port: Int
    private let channel: any Channel

    static func start(on group: MultiThreadedEventLoopGroup) async throws -> IntegServer {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(IntegHandler())
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return IntegServer(port: ch.localAddress!.port!, channel: ch)
    }

    private init(port: Int, channel: any Channel) {
        self.port = port
        self.channel = channel
    }

    func stop() async throws { try await channel.close() }
}

// MARK: - Runner

@main
enum IntegrationSmokeRunner {
    static func main() async throws {
        try await runIntegration()
    }
}

func runIntegration() async throws {
    // Временный sqlite-файл.
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailai-integ-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let dbURL = tmpDir.appendingPathComponent("metadata.sqlite")

    let store = try GRDBMetadataStore(url: dbURL)

    // Заводим аккаунт и папку в БД — упрощённые, без онбординга.
    let account = Account(
        id: Account.ID(ACCOUNT_ID_RAW),
        email: "bob@example.com",
        displayName: nil,
        kind: .imap,
        host: "127.0.0.1",
        port: 1,
        security: .none,
        username: "bob"
    )
    try await store.upsert(account)
    let mailbox = Mailbox(
        id: Mailbox.ID(MAILBOX_ID_RAW),
        accountID: account.id,
        name: "INBOX",
        path: "INBOX",
        role: .inbox,
        unreadCount: 0,
        totalCount: 1,
        uidValidity: 42
    )
    try await store.upsert(mailbox)

    // Поднимаем сервер.
    let group = MultiThreadedEventLoopGroup.singleton
    let server = try await IntegServer.start(on: group)
    defer { Task { try? await server.stop() } }
    let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

    let provider = LiveAccountDataProvider(account: account, store: store)
    var bodyBytes: [UInt8]? = []

    try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
        try await conn.login(username: "bob", password: "secret")
        _ = try await conn.select("INBOX")

        // Синхронизируем заголовки через LiveAccountDataProvider (B6).
        let result = try await provider.syncHeaders(
            mailbox: mailbox.id,
            uidRange: IMAPUIDRange(lower: 1, upper: 1),
            using: conn
        )
        check("syncHeaders fetched 1 message", result.fetched == 1)
        check("syncHeaders upserted 1 message", result.upserted == 1)

        // Стримим тело в память — инвариант «в памяти, не на диске».
        let body = try await conn.fetchBody(uid: 1)
        bodyBytes = body
        let bodyString = String(bytes: body, encoding: .utf8) ?? ""
        check("MessageBody содержит SECRET_TOKEN в памяти",
              bodyString.contains(SECRET_TOKEN))

        try await conn.logout()
    }

    // «Закрываем окно» — обнуляем ссылки. AccountSessionModel.closeSession
    // делает ровно это: openBody = nil, messages = [].
    bodyBytes = nil
    _ = bodyBytes  // чтобы компилятор не жаловался на unused

    // Закрываем pool и ждём, пока WAL зафиксируется.
    // GRDB checkpoint'ит WAL при закрытии pool. Здесь DBPool — внутри actor,
    // мы не можем его напрямую закрыть, но явный read-транзакции хватает
    // для flush WAL-файла.
    _ = try await store.messages(in: mailbox.id, page: .init(offset: 0, limit: 100))

    // Grep sqlite-файла и всех WAL-вариантов: должно быть 0 вхождений токена.
    let files = try FileManager.default.contentsOfDirectory(
        at: tmpDir, includingPropertiesForKeys: nil
    )
    check("в tmpDir есть sqlite-файл(ы)", !files.isEmpty)

    let tokenBytes = Array(SECRET_TOKEN.utf8)
    var foundIn: [String] = []
    for file in files {
        let data = try Data(contentsOf: file)
        if data.range(of: Data(tokenBytes)) != nil {
            foundIn.append(file.lastPathComponent)
        }
    }
    check("SECRET_TOKEN отсутствует во всех файлах БД (\(files.count) шт.)",
          foundIn.isEmpty)

    print("✅ IntegrationSmoke OK (files scanned: \(files.map(\.lastPathComponent).joined(separator: ", ")))")
}
