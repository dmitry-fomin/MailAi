import Foundation
import Core
import MailTransport
import NIOCore
import NIOPosix

// IMAPPerfSmoke — perf-smoke B10.
// Поднимает локальный TCP-сервер, эмулирующий UID FETCH 1:1000 с полноценными
// заголовками (UID/FLAGS/INTERNALDATE/RFC822.SIZE/ENVELOPE/BODYSTRUCTURE),
// прогоняет IMAPConnection.uidFetchHeaders и проверяет, что:
//   • получено ровно 1000 FETCH-ответов
//   • общее время ≤ 2 секунды
//
// Запуск: swift run IMAPPerfSmoke  (из корня или из Packages/MailTransport).
// Без env, без сети в интернет.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

func check(_ label: String, _ condition: Bool) {
    guard condition else { die(label) }
    print("✓ \(label)")
}

// MARK: - Fake IMAP server

final class PerfServerHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = IMAPLine
    typealias OutboundOut = IMAPLine

    let messageCount: Int
    init(messageCount: Int) { self.messageCount = messageCount }

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(IMAPLine("* OK IMAP4rev1 perf server ready")), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data).raw
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count >= 2 else {
            write(context, IMAPLine("\(parts.first ?? "*") BAD"))
            return
        }
        let tag = parts[0]
        let cmd = parts[1].uppercased()
        if cmd.hasPrefix("UID FETCH") {
            for seq in 1...messageCount {
                write(context, IMAPLine(Self.fetchLine(seq: UInt32(seq), uid: UInt32(seq))))
            }
            write(context, IMAPLine("\(tag) OK FETCH completed"))
        } else if cmd.hasPrefix("LOGOUT") {
            write(context, IMAPLine("* BYE"))
            write(context, IMAPLine("\(tag) OK LOGOUT completed"))
        } else {
            write(context, IMAPLine("\(tag) OK"))
        }
        context.flush()
    }

    private func write(_ context: ChannelHandlerContext, _ line: IMAPLine) {
        context.write(wrapOutboundOut(line), promise: nil)
    }

    static func fetchLine(seq: UInt32, uid: UInt32) -> String {
        let envelope = """
        ENVELOPE ("Tue, 17 Apr 2026 10:30:42 +0300" "Perf subject \(uid)" \
        (("Alice" NIL "alice" "example.com")) \
        (("Alice" NIL "alice" "example.com")) \
        (("Alice" NIL "alice" "example.com")) \
        (("Bob" NIL "bob" "example.com")) \
        NIL NIL NIL "<perf-\(uid)@example.com>")
        """
        let body = "BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 512 10)"
        return "* \(seq) FETCH (UID \(uid) FLAGS (\\Seen) INTERNALDATE \"17-Apr-2026 10:30:42 +0300\" RFC822.SIZE 4096 \(envelope) \(body))"
    }
}

actor PerfServer {
    let port: Int
    private let channel: any Channel

    static func start(on group: MultiThreadedEventLoopGroup, messageCount: Int) async throws -> PerfServer {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(PerfServerHandler(messageCount: messageCount))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return PerfServer(port: ch.localAddress!.port!, channel: ch)
    }

    private init(port: Int, channel: any Channel) {
        self.port = port
        self.channel = channel
    }

    func stop() async throws { try await channel.close() }
}

@main
enum IMAPPerfSmokeRunner {
    static func main() async throws {
        try await runPerf()
    }
}

func runPerf() async throws {
    let messageCount = Int(ProcessInfo.processInfo.environment["PERF_COUNT"] ?? "") ?? 1000
    let budgetSeconds: Double = 2.0
    let group = MultiThreadedEventLoopGroup.singleton

    let server = try await PerfServer.start(on: group, messageCount: messageCount)
    defer { Task { try? await server.stop() } }

    let port = server.port
    let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, security: .plain)

    FileHandle.standardError.write(Data("▶ UID FETCH 1:\(messageCount) через локальный fake-сервер на 127.0.0.1:\(port)\n".utf8))

    let start = DispatchTime.now()
    let (fetchedCount, parseErrorsCount): (Int, Int) = try await IMAPConnection.withOpen(
        endpoint: endpoint, eventLoopGroup: group
    ) { conn in
        let range = IMAPUIDRange(lower: 1, upper: UInt32(messageCount))
        let (fetches, parseErrors) = try await conn.uidFetchHeaders(range: range)
        try await conn.logout()
        return (fetches.count, parseErrors)
    }

    let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000

    FileHandle.standardError.write(Data(String(format: "ℹ elapsed=%.3fs parseErrors=%d\n", elapsedSeconds, parseErrorsCount).utf8))

    check("получено \(messageCount) FETCH-ответов", fetchedCount == messageCount)
    check("parseErrors == 0", parseErrorsCount == 0)
    check(String(format: "FETCH 1000 headers выполнен за ≤ %.1fs (факт: %.3fs)", budgetSeconds, elapsedSeconds),
          elapsedSeconds <= budgetSeconds)

    print("✅ IMAPPerfSmoke OK")
}
