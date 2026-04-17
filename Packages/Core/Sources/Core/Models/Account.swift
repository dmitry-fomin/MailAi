import Foundation

/// Почтовый аккаунт пользователя. Секреты (пароли/токены) здесь не хранятся —
/// только идентификатор, по которому их можно достать из Keychain.
public struct Account: Sendable, Hashable, Identifiable, Codable {
    public struct ID: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }

    public enum Kind: String, Sendable, Hashable, Codable {
        case imap
        case exchange
    }

    public enum Security: String, Sendable, Hashable, Codable {
        case tls
        case startTLS
        case none
    }

    public let id: ID
    public let email: String
    public let displayName: String?
    public let kind: Kind
    public let host: String
    public let port: UInt16
    public let security: Security
    public let username: String

    public init(
        id: ID,
        email: String,
        displayName: String?,
        kind: Kind,
        host: String,
        port: UInt16,
        security: Security,
        username: String
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }
}
