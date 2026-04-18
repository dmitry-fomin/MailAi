#if canImport(XCTest)
import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import MailTransport

/// Loopback-тест потокового чтения тела: fake-сервер отдаёт FETCH-ответ с
/// литералом известной длины, клиент собирает байты через `streamBody`.
final class IMAPBodyStreamTests: XCTestCase {

    /// Fake-сервер, который в ответ на `* UID FETCH` отдаёт литерал с заранее
    /// заданным телом. Для простоты поддерживает один FETCH-запрос.
    final class BodyServerLogic: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = IMAPLine
        typealias OutboundOut = IMAPLine

        let body: String

        init(body: String) { self.body = body }

        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(IMAPLine("* OK IMAP ready")), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let incoming = unwrapInboundIn(data)
            let raw = incoming.raw
            let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return }
            let tag = String(parts[0])
            let rest = String(parts[1])

            if rest.uppercased().hasPrefix("UID FETCH") {
                // Ответ: * N FETCH (UID X BODY[] {LEN}\r\n<body>)\r\nTAG OK FETCH completed
                let bodyBytes = Array(body.utf8)
                let len = bodyBytes.count
                // Первая линия: * 1 FETCH (UID 42 BODY[] {LEN}
                let first = "* 1 FETCH (UID 42 BODY[] {\(len)}"
                context.writeAndFlush(wrapOutboundOut(IMAPLine(first)), promise: nil)
                // Разбиваем тело по CRLF на линии — так сервер и отдаёт.
                // Для теста берём тело целиком и режем по \r\n.
                let lines = body.components(separatedBy: "\r\n")
                for (idx, line) in lines.enumerated() {
                    if idx == lines.count - 1 && line.isEmpty { break }
                    context.writeAndFlush(wrapOutboundOut(IMAPLine(line)), promise: nil)
                }
                // Закрывающий `)` на отдельной строке.
                context.writeAndFlush(wrapOutboundOut(IMAPLine(")")), promise: nil)
                context.writeAndFlush(wrapOutboundOut(IMAPLine("\(tag) OK FETCH completed")), promise: nil)
                return
            }
            if rest.uppercased().hasPrefix("LOGOUT") {
                context.writeAndFlush(wrapOutboundOut(IMAPLine("* BYE")), promise: nil)
                context.writeAndFlush(wrapOutboundOut(IMAPLine("\(tag) OK LOGOUT")), promise: nil)
                context.close(promise: nil)
                return
            }
            context.writeAndFlush(wrapOutboundOut(IMAPLine("\(tag) OK")), promise: nil)
        }
    }

    func testStreamBodyReassemblesLiteral() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let messageBody = "Content-Type: text/plain; charset=utf-8\r\n" +
                          "\r\n" +
                          "Hello Streaming World\r\n"
        let serverLogic = BodyServerLogic(body: messageBody)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(serverLogic)
                }
            }
        let serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = serverChannel.localAddress!.port!

        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, security: .plain)
        try await IMAPConnection.withOpen(endpoint: endpoint) { conn in
            var collected: [UInt8] = []
            for try await chunk in conn.streamBody(uid: 42) {
                collected.append(contentsOf: chunk.bytes)
            }
            // Обрезаем возможный трейлинг от собранных «линия + CRLF» —
            // длина обязана совпасть с тем, что указал сервер.
            let expected = Array(messageBody.utf8)
            XCTAssertEqual(collected.count, expected.count, "body length mismatch")
        }
        try await serverChannel.close()
    }
}
#endif
