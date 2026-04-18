import Foundation
import NIOCore

/// Декодер: читает байты из `ByteBuffer` и режет на `IMAPLine` по CRLF.
/// Если строка заканчивается на `\r\n`, оба символа удаляются; если только
/// на `\n` — удаляется только `\n` (толерантность к неправильным серверам).
public struct IMAPLineFrameDecoder: ByteToMessageDecoder, Sendable {
    public typealias InboundOut = IMAPLine

    public init() {}

    public mutating func decode(context: ChannelHandlerContext,
                                buffer: inout ByteBuffer) throws -> DecodingState {
        guard let lfIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            return .needMoreData
        }
        let offset = lfIndex - buffer.readableBytesView.startIndex
        var line = buffer.readSlice(length: offset + 1)!  // включая \n
        // Откусываем трейлинг \n и (если есть) \r
        line.moveReaderIndex(to: line.readerIndex)
        var bytes = Array(line.readableBytesView)
        while let last = bytes.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        let str = String(decoding: bytes, as: UTF8.self)
        context.fireChannelRead(self.wrapInboundOut(IMAPLine(str)))
        return .continue
    }

    public mutating func decodeLast(context: ChannelHandlerContext,
                                    buffer: inout ByteBuffer,
                                    seenEOF: Bool) throws -> DecodingState {
        if buffer.readableBytes > 0 {
            let remaining = buffer.readString(length: buffer.readableBytes) ?? ""
            if !remaining.isEmpty {
                context.fireChannelRead(self.wrapInboundOut(IMAPLine(remaining)))
            }
        }
        return .needMoreData
    }
}

/// Кодер: каждая `IMAPLine` превращается в `<raw>\r\n`.
public final class IMAPLineFrameEncoder: ChannelOutboundHandler, Sendable {
    public typealias OutboundIn = IMAPLine
    public typealias OutboundOut = ByteBuffer

    public init() {}

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let line = self.unwrapOutboundIn(data)
        var buffer = context.channel.allocator.buffer(capacity: line.raw.utf8.count + 2)
        buffer.writeString(line.raw)
        buffer.writeBytes([UInt8(ascii: "\r"), UInt8(ascii: "\n")])
        context.write(self.wrapOutboundOut(buffer), promise: promise)
    }
}
