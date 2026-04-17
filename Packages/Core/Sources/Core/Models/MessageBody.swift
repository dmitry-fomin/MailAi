import Foundation

/// Тело письма. Живёт в памяти только пока письмо открыто.
/// НИКОГДА не сериализуется, не кладётся в БД и не пишется в лог.
/// Инвариант проверяется тестом `NoBodyInStorageTests` на стороне Storage.
public struct MessageBody: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        case plain(String)
        case html(String)
    }

    public let messageID: Message.ID
    public let content: Content
    public let attachments: [Attachment]

    public init(messageID: Message.ID, content: Content, attachments: [Attachment] = []) {
        self.messageID = messageID
        self.content = content
        self.attachments = attachments
    }
}

/// Чанк тела для стриминговой загрузки.
public struct ByteChunk: Sendable, Hashable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) { self.bytes = bytes }
}
