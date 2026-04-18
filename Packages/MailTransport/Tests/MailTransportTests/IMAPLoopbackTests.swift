#if canImport(XCTest)
import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import MailTransport

/// Интеграционный тест end-to-end pipeline: локальный TCP-сервер на NIO +
/// реальный `IMAPClientBootstrap.connect(.plain)`. TLS не тестируется здесь
/// (нужны сертификаты); для TLS есть отдельный smoke-тест с opt-in в env.
final class IMAPLoopbackTests: XCTestCase {

    /// Минимальный echo-like сервер: принимает линии, отвечает `* OK <line>`
    /// для каждой входящей.
    actor FakeServer {
        let port: Int
        private let channel: any Channel

        static func start(on group: MultiThreadedEventLoopGroup) async throws -> FakeServer {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                        try sync.addHandler(IMAPLineFrameEncoder())
                        try sync.addHandler(ServerLogic())
                    }
                }
            let serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            let port = serverChannel.localAddress!.port!
            // Greeting → отправим после подключения клиента (ServerLogic сделает).
            return FakeServer(port: port, channel: serverChannel)
        }

        private init(port: Int, channel: any Channel) {
            self.port = port
            self.channel = channel
        }

        func stop() async throws {
            try await channel.close()
        }
    }

    final class ServerLogic: ChannelInboundHandler, Sendable {
        typealias InboundIn = IMAPLine
        typealias OutboundOut = IMAPLine

        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(IMAPLine("* OK IMAP fake server ready")), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let incoming = unwrapInboundIn(data)
            context.writeAndFlush(wrapOutboundOut(IMAPLine("* OK echo \(incoming.raw)")), promise: nil)
        }
    }

    func testClientConnectsReceivesGreetingAndRoundtrip() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await FakeServer.start(on: group)

        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)
        let client = try await IMAPClientBootstrap.connect(to: endpoint, eventLoopGroup: group)

        try await client.executeThenClose { inbound, outbound in
            var iter = inbound.makeAsyncIterator()
            let greeting = try await iter.next()
            XCTAssertEqual(greeting?.raw, "* OK IMAP fake server ready")

            try await outbound.write(IMAPLine("a001 CAPABILITY"))
            let echo = try await iter.next()
            XCTAssertEqual(echo?.raw, "* OK echo a001 CAPABILITY")

            try await outbound.write(IMAPLine("a002 LOGOUT"))
            let echo2 = try await iter.next()
            XCTAssertEqual(echo2?.raw, "* OK echo a002 LOGOUT")
        }
        try await server.stop()
    }

    func testConnectionRefusedFailsFast() async throws {
        let group = MultiThreadedEventLoopGroup.singleton

        // Порт 1 — гарантированно закрыт
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 1, security: .plain)
        do {
            _ = try await IMAPClientBootstrap.connect(
                to: endpoint,
                eventLoopGroup: group,
                connectTimeout: .seconds(1)
            )
            XCTFail("Expected connection to fail")
        } catch {
            // Ожидаем NIO-ошибку подключения
            XCTAssertTrue(true, "Got expected error: \(error)")
        }
    }
}
#endif
