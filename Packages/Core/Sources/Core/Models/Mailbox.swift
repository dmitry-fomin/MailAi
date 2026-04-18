import Foundation

/// Папка почтового ящика (IMAP mailbox / Exchange folder).
public struct Mailbox: Sendable, Hashable, Identifiable, Codable {
    public struct ID: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }

    /// Системная роль папки. Позволяет UI иконизировать и сортировать папки
    /// независимо от их локализованных имён на сервере.
    public enum Role: String, Sendable, Hashable, Codable {
        case inbox
        case sent
        case drafts
        case archive
        case trash
        case spam
        case flagged
        case custom
    }

    public let id: ID
    public let accountID: Account.ID
    public let name: String
    public let path: String
    public let role: Role
    public let unreadCount: Int
    public let totalCount: Int
    public let uidValidity: UInt32?
    public let children: [Mailbox]

    public init(
        id: ID,
        accountID: Account.ID,
        name: String,
        path: String,
        role: Role,
        unreadCount: Int,
        totalCount: Int,
        uidValidity: UInt32?,
        children: [Mailbox] = []
    ) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.path = path
        self.role = role
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.uidValidity = uidValidity
        self.children = children
    }
}
