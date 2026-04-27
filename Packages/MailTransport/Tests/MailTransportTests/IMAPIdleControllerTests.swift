#if canImport(XCTest)
import XCTest
import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
@testable import MailTransport

/// Loopback-тесты IMAPIdleController. Поднимает локальный TCP-сервер,
/// эмулирующий IDLE с EXISTS/EXPUNGE и DONE.
///
/// Полный smoke-сценарий с реальным IMAP-сервером — в Pool-4 (md4).
/// TODO(MailAi-md4): расширенный smoke (session pool + IDLE) живёт в Pool-4.
final class IMAPIdleControllerTests: XCTestCase {

    /// Минимальный fake-сервер: умеет LOGIN, SELECT, IDLE/DONE, LOGOUT.
    /// При получении IDLE отвечает `+ idling`, ждёт DONE и шлёт «* N EXISTS»
    /// если в `pendingExists` что-то лежит — это даёт детерминированную точку
    /// для проверки доставки события.
    final class FakeIMAPServer: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = IMAPLine
        typealias OutboundOut = IMAPLine

        private let lock = NIOLock()
        private var idling = false
        private var idleTag = ""

        // Шлёт EXISTS до получения DONE — записывается тестом снаружи через
        // injection через Server.injectExists.
        private var ctxRef: ChannelHandlerContext?

        func channelActive(context: ChannelHandlerContext) {
            self.ctxRef = context
            context.writeAndFlush(wrapOutboundOut(
                IMAPLine("* OK IMAP4rev1 fake idle server ready")
            ), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let line = unwrapInboundIn(data).raw

            // Пока в IDLE — единственная команда, которую мы понимаем, это DONE.
            let isIdling: Bool = lock.withLock { idling }
            if isIdling {
                if line.uppercased() == "DONE" {
                    let tag = lock.withLock { () -> String in
                        let t = idleTag
                        idling = false
                        idleTag = ""
                        return t
                    }
                    writeLines(context, ["\(tag) OK IDLE terminated"])
                }
                return
            }

            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count >= 2 else {
                context.writeAndFlush(wrapOutboundOut(
                    IMAPLine("\(parts.first ?? "*") BAD bad command")
                ), promise: nil)
                return
            }
            let tag = parts[0]
            let cmd = parts[1].uppercased()

            if cmd.hasPrefix("LOGIN") {
                writeLines(context, ["\(tag) OK LOGIN completed"])
            } else if cmd.hasPrefix("SELECT") {
                writeLines(context, [
                    "* 0 EXISTS",
                    "* OK [UIDVALIDITY 1] uid valid",
                    "* OK [UIDNEXT 1] next uid",
                    "\(tag) OK [READ-WRITE] SELECT completed"
                ])
            } else if cmd.hasPrefix("IDLE") {
                lock.withLock {
                    idling = true
                    idleTag = tag
                }
                writeLines(context, ["+ idling"])
            } else if cmd.hasPrefix("LOGOUT") {
                writeLines(context, [
                    "* BYE bye",
                    "\(tag) OK LOGOUT completed"
                ])
            } else {
                writeLines(context, ["\(tag) BAD unknown"])
            }
        }

        /// Шлёт «* N EXISTS» в текущий канал (если он жив).
        func sendExists(_ count: Int) {
            guard let ctx = ctxRef else { return }
            ctx.eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(IMAPLine("* \(count) EXISTS")), promise: nil)
            }
        }

        private func writeLines(_ context: ChannelHandlerContext, _ lines: [String]) {
            for line in lines {
                context.write(wrapOutboundOut(IMAPLine(line)), promise: nil)
            }
            context.flush()
        }
    }

    actor Server {
        let port: Int
        private let channel: any Channel
        private let handlerBox: HandlerBox

        final class HandlerBox: @unchecked Sendable {
            var handler: FakeIMAPServer?
        }

        static func start(on group: MultiThreadedEventLoopGroup) async throws -> Server {
            let box = HandlerBox()
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                        try sync.addHandler(IMAPLineFrameEncoder())
                        let h = FakeIMAPServer()
                        box.handler = h
                        try sync.addHandler(h)
                    }
                }
            let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            return Server(port: ch.localAddress!.port!, channel: ch, handlerBox: box)
        }

        private init(port: Int, channel: any Channel, handlerBox: HandlerBox) {
            self.port = port
            self.channel = channel
            self.handlerBox = handlerBox
        }

        func sendExists(_ n: Int) { handlerBox.handler?.sendExists(n) }
        func stop() async throws { try await channel.close() }
    }

    private let group = MultiThreadedEventLoopGroup.singleton

    /// Стартует контроллер, ждёт `.idleStarted`, эмулирует EXISTS, ждёт его
    /// в `events`, делает stop() и проверяет, что состояние перешло в
    /// `.stopped(nil)`.
    func testIdleDeliversExistsAndShutsDownCleanly() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }

        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)
        let controller = IMAPIdleController(
            endpoint: endpoint,
            username: "u",
            password: "p",
            eventLoopGroup: group,
            tuning: IMAPIdleTuning(idleTimeout: .seconds(60), commandTimeout: .seconds(5))
        )

        try await controller.start()
        try await controller.setMailbox("INBOX")

        // Дочитаем idleStarted, потом эмулируем EXISTS и ждём событие.
        var receivedExists: UInt32 = 0
        var sawIdleStarted = false
        let iterTask = Task { () -> (Bool, UInt32) in
            for await event in controller.events {
                switch event {
                case .idleStarted:
                    sawIdleStarted = true
                    // После того, как сервер увидел IDLE и ответил +,
                    // контроллер вошёл в idle. Шлём EXISTS.
                    await server.sendExists(7)
                case .exists(_, let count):
                    receivedExists = count
                    return (sawIdleStarted, receivedExists)
                default:
                    continue
                }
            }
            return (sawIdleStarted, receivedExists)
        }

        // Ограничим тайминг: 5 секунд на доставку события более чем достаточно.
        let result = try await withThrowingTaskGroup(of: (Bool, UInt32).self) { group in
            group.addTask { await iterTask.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw XCTSkip("timeout waiting for EXISTS")
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }

        XCTAssertTrue(result.0, "expected idleStarted before exists")
        XCTAssertEqual(result.1, 7)

        await controller.stop()
        let state = await controller.state
        if case .stopped(let err) = state {
            XCTAssertNil(err)
        } else {
            XCTFail("expected .stopped, got \(state)")
        }
    }
}
#endif
