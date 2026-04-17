import Foundation

/// Тред — последовательность писем, связанных In-Reply-To / References.
/// Назван `MessageThread`, чтобы не конфликтовать с `Foundation.Thread`.
public struct MessageThread: Sendable, Hashable, Identifiable, Codable {
    public struct ID: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }

    public let id: ID
    public let accountID: Account.ID
    public let subject: String
    public let messageIDs: [Message.ID]
    public let lastDate: Date

    public init(
        id: ID,
        accountID: Account.ID,
        subject: String,
        messageIDs: [Message.ID],
        lastDate: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.subject = subject
        self.messageIDs = messageIDs
        self.lastDate = lastDate
    }
}
