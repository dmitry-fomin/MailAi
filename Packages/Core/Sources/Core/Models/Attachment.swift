import Foundation

/// Метаданные вложения. Сам бинарный контент никогда не лежит в БД —
/// загружается стримом при запросе пользователя.
public struct Attachment: Sendable, Hashable, Identifiable, Codable {
    public struct ID: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }

    public let id: ID
    public let messageID: Message.ID
    public let filename: String
    public let mimeType: String
    public let size: Int
    /// IMAP part number (например, "2.1"). Нужен для FETCH BODY[partNumber].
    public let partNumber: String?
    public let isInline: Bool

    public init(
        id: ID,
        messageID: Message.ID,
        filename: String,
        mimeType: String,
        size: Int,
        partNumber: String?,
        isInline: Bool
    ) {
        self.id = id
        self.messageID = messageID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.partNumber = partNumber
        self.isInline = isInline
    }
}
