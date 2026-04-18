#if canImport(XCTest)
import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import MailTransport

/// Loopback-тесты команд IMAPConnection. Поднимает локальный TCP-сервер,
/// эмулирующий стандартные ответы Dovecot-подобного IMAP-сервера.
final class IMAPCommandsLoopbackTests: XCTestCase {

    /// Серверная логика: знает CAPABILITY, LOGIN, LIST, SELECT, LOGOUT.
    /// Пример — минимальный, но достаточный для проверки типизированных команд.
    final class FakeIMAPServer: ChannelInboundHandler, Sendable {
        typealias InboundIn = IMAPLine
        typealias OutboundOut = IMAPLine

        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(
                IMAPLine("* OK IMAP4rev1 fake server ready")
            ), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let line = unwrapInboundIn(data).raw
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count >= 2 else {
                context.writeAndFlush(wrapOutboundOut(
                    IMAPLine("\(parts.first ?? "*") BAD bad command")
                ), promise: nil)
                return
            }
            let tag = parts[0]
            let cmd = parts[1].uppercased()

            if cmd.hasPrefix("CAPABILITY") {
                writeLines(context, [
                    "* CAPABILITY IMAP4rev1 IDLE UIDPLUS LITERAL+",
                    "\(tag) OK CAPABILITY completed"
                ])
            } else if cmd.hasPrefix("LOGIN") {
                if cmd.contains("WRONG") {
                    writeLines(context, ["\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials"])
                } else {
                    writeLines(context, ["\(tag) OK LOGIN completed"])
                }
            } else if cmd.hasPrefix("LIST") {
                writeLines(context, [
                    "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
                    "* LIST (\\HasChildren) \"/\" \"Sent\"",
                    "* LIST (\\HasNoChildren) \"/\" \"Trash\"",
                    "\(tag) OK LIST completed"
                ])
            } else if cmd.hasPrefix("SELECT INBOX") || cmd.hasPrefix("SELECT \"INBOX\"") {
                writeLines(context, [
                    "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)",
                    "* 172 EXISTS",
                    "* 1 RECENT",
                    "* OK [UIDVALIDITY 3857529045] UIDs valid",
                    "* OK [UIDNEXT 4392] Predicted next UID",
                    "\(tag) OK [READ-WRITE] SELECT completed"
                ])
            } else if cmd.hasPrefix("LOGOUT") {
                writeLines(context, [
                    "* BYE IMAP4rev1 Server logging out",
                    "\(tag) OK LOGOUT completed"
                ])
            } else {
                writeLines(context, ["\(tag) BAD unknown command"])
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

        static func start(on group: MultiThreadedEventLoopGroup) async throws -> Server {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                        try sync.addHandler(IMAPLineFrameEncoder())
                        try sync.addHandler(FakeIMAPServer())
                    }
                }
            let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            return Server(port: ch.localAddress!.port!, channel: ch)
        }

        private init(port: Int, channel: any Channel) {
            self.port = port
            self.channel = channel
        }

        func stop() async throws { try await channel.close() }
    }

    private let group = MultiThreadedEventLoopGroup.singleton

    func testGreetingReceived() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

        try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
            XCTAssertTrue(conn.greeting.raw.contains("IMAP4rev1 fake server"))
        }
    }

    func testCapability() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

        try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
            let caps = try await conn.capability()
            XCTAssertTrue(caps.contains("IMAP4rev1"))
            XCTAssertTrue(caps.contains("IDLE"))
            XCTAssertTrue(caps.contains("UIDPLUS"))
        }
    }

    func testLoginSuccess() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

        try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
            try await conn.login(username: "user", password: "pass")
        }
    }

    func testLoginFailureThrows() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

        do {
            try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
                try await conn.login(username: "user", password: "WRONG")
            }
            XCTFail("Expected NO response to throw")
        } catch let error as IMAPConnectionError {
            if case .commandFailed(let status, _) = error {
                XCTAssertEqual(status, .no)
            } else {
                XCTFail("Wrong case: \(error)")
            }
        }
    }

    func testList() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

        try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
            let entries = try await conn.list()
            XCTAssertEqual(entries.count, 3)
            XCTAssertEqual(entries.map(\.path), ["INBOX", "Sent", "Trash"])
            XCTAssertTrue(entries[0].flags.contains("\\HasNoChildren"))
        }
    }

    func testSelectInbox() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

        try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
            let result = try await conn.select("INBOX")
            XCTAssertEqual(result.exists, 172)
            XCTAssertEqual(result.recent, 1)
            XCTAssertEqual(result.uidValidity, 3857529045)
            XCTAssertEqual(result.uidNext, 4392)
            XCTAssertFalse(result.readOnly)
            XCTAssertTrue(result.flags.contains("\\Seen"))
        }
    }

    func testFullSessionRoundtrip() async throws {
        let server = try await Server.start(on: group)
        defer { Task { try? await server.stop() } }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: server.port, security: .plain)

        try await IMAPConnection.withOpen(endpoint: endpoint, eventLoopGroup: group) { conn in
            let caps = try await conn.capability()
            XCTAssertFalse(caps.isEmpty)
            try await conn.login(username: "user", password: "pass")
            let list = try await conn.list()
            XCTAssertFalse(list.isEmpty)
            let select = try await conn.select("INBOX")
            XCTAssertGreaterThan(select.exists, 0)
            try await conn.logout()
        }
    }
}
#endif
