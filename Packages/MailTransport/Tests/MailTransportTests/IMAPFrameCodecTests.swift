#if canImport(XCTest)
import XCTest
import NIOCore
import NIOEmbedded
@testable import MailTransport

final class IMAPFrameCodecTests: XCTestCase {

    func testDecoderSplitsByCRLF() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(IMAPLineFrameDecoder())
        )
        var buf = ByteBuffer()
        buf.writeString("* OK Hello\r\n* CAPABILITY IMAP4rev1\r\n")
        try channel.writeInbound(buf)

        let l1 = try channel.readInbound(as: IMAPLine.self)
        let l2 = try channel.readInbound(as: IMAPLine.self)
        XCTAssertEqual(l1?.raw, "* OK Hello")
        XCTAssertEqual(l2?.raw, "* CAPABILITY IMAP4rev1")
        _ = try channel.finish()
    }

    func testDecoderToleratesBareLF() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(IMAPLineFrameDecoder())
        )
        var buf = ByteBuffer()
        buf.writeString("line-without-cr\n")
        try channel.writeInbound(buf)
        let l1 = try channel.readInbound(as: IMAPLine.self)
        XCTAssertEqual(l1?.raw, "line-without-cr")
        _ = try channel.finish()
    }

    func testDecoderBuffersIncompleteLine() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(IMAPLineFrameDecoder())
        )

        var part1 = ByteBuffer()
        part1.writeString("* OK gr")
        try channel.writeInbound(part1)
        XCTAssertNil(try channel.readInbound(as: IMAPLine.self))

        var part2 = ByteBuffer()
        part2.writeString("eeting\r\n")
        try channel.writeInbound(part2)
        let line = try channel.readInbound(as: IMAPLine.self)
        XCTAssertEqual(line?.raw, "* OK greeting")
        _ = try channel.finish()
    }

    func testEncoderAddsCRLF() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(IMAPLineFrameEncoder())
        try channel.writeOutbound(IMAPLine("a001 LOGIN user pass"))
        let buf: ByteBuffer? = try channel.readOutbound(as: ByteBuffer.self)
        XCTAssertNotNil(buf)
        let str = buf.flatMap { String(buffer: $0) }
        XCTAssertEqual(str, "a001 LOGIN user pass\r\n")
        _ = try channel.finish()
    }

    func testRoundTripThroughBothHandlers() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(IMAPLineFrameDecoder())
        )
        try channel.pipeline.syncOperations.addHandler(IMAPLineFrameEncoder())

        // Отправили — на выходе должен быть CRLF-закодированный ByteBuffer
        try channel.writeOutbound(IMAPLine("a002 CAPABILITY"))
        let out: ByteBuffer? = try channel.readOutbound(as: ByteBuffer.self)
        XCTAssertEqual(out.flatMap { String(buffer: $0) }, "a002 CAPABILITY\r\n")

        // Приняли ответ — декодер выдал IMAPLine без CRLF
        var resp = ByteBuffer()
        resp.writeString("a002 OK\r\n")
        try channel.writeInbound(resp)
        let line = try channel.readInbound(as: IMAPLine.self)
        XCTAssertEqual(line?.raw, "a002 OK")
        _ = try channel.finish()
    }

    func testIMAPLineMaskedHidesLongTokens() {
        let line = IMAPLine("a003 LOGIN user@example.com supersecretpasswordverylong1234567890")
        let masked = line.masked
        XCTAssertFalse(masked.contains("supersecretpassword"))
        XCTAssertTrue(masked.contains("a003"))
        XCTAssertTrue(masked.contains("LOGIN"))
    }
}
#endif
