import Foundation
import Core
#if canImport(Security)
import Security
#endif

/// Реальная реализация `SecretsStore` поверх Keychain Services (Security.framework).
///
/// Элементы сохраняются как `kSecClassGenericPassword` с ключом
/// `service = "mailai.<accountId>.<kind>"`, `account = username`.
///
/// Никогда не логируем значения; все ошибки оборачиваем в
/// `MailError.keychain(.unknown)` без деталей.
public actor KeychainService: SecretsStore {
    public enum Kind: String, Sendable {
        case password
        case oauthRefreshToken
        case openrouter
        case smtpPassword
    }

    private let servicePrefix: String
    private let usernameProvider: @Sendable (Account.ID) -> String

    public init(
        servicePrefix: String = "mailai",
        usernameProvider: @escaping @Sendable (Account.ID) -> String = { $0.rawValue }
    ) {
        self.servicePrefix = servicePrefix
        self.usernameProvider = usernameProvider
    }

    public func setPassword(_ password: String, forAccount accountID: Account.ID) async throws {
        try await set(value: password, kind: .password, forAccount: accountID)
    }

    public func password(forAccount accountID: Account.ID) async throws -> String? {
        try await value(kind: .password, forAccount: accountID)
    }

    public func deletePassword(forAccount accountID: Account.ID) async throws {
        try await delete(kind: .password, forAccount: accountID)
    }

    public func setOpenRouterKey(_ key: String, forAccount accountID: Account.ID) async throws {
        try await set(value: key, kind: .openrouter, forAccount: accountID)
    }

    public func openRouterKey(forAccount accountID: Account.ID) async throws -> String? {
        try await value(kind: .openrouter, forAccount: accountID)
    }

    public func deleteOpenRouterKey(forAccount accountID: Account.ID) async throws {
        try await delete(kind: .openrouter, forAccount: accountID)
    }

    public func setSMTPPassword(_ password: String, forAccount accountID: Account.ID) async throws {
        try await set(value: password, kind: .smtpPassword, forAccount: accountID)
    }

    public func smtpPassword(forAccount accountID: Account.ID) async throws -> String? {
        try await value(kind: .smtpPassword, forAccount: accountID)
    }

    public func deleteSMTPPassword(forAccount accountID: Account.ID) async throws {
        try await delete(kind: .smtpPassword, forAccount: accountID)
    }

    // MARK: - Generic kind-aware API

    public func set(value: String, kind: Kind, forAccount accountID: Account.ID) async throws {
        #if canImport(Security)
        let data = Data(value.utf8)
        let service = makeService(kind: kind, accountID: accountID)
        let account = usernameProvider(accountID)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let attrs: [CFString: Any] = [
            kSecValueData: data,
            // kSecAttrAccessibleWhenUnlocked: секрет доступен только пока устройство разблокировано.
            // Если потребуется фоновый доступ (push-уведомления) — использовать
            // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, но не AfterFirstUnlock.
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            for (k, v) in attrs { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MailError.keychain(reason(for: addStatus))
            }
        default:
            throw MailError.keychain(reason(for: updateStatus))
        }
        #else
        throw MailError.keychain(.unknown)
        #endif
    }

    public func value(kind: Kind, forAccount accountID: Account.ID) async throws -> String? {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: makeService(kind: kind, accountID: accountID),
            kSecAttrAccount: usernameProvider(accountID),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw MailError.keychain(reason(for: status))
        }
        #else
        return nil
        #endif
    }

    public func delete(kind: Kind, forAccount accountID: Account.ID) async throws {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: makeService(kind: kind, accountID: accountID),
            kSecAttrAccount: usernameProvider(accountID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw MailError.keychain(reason(for: status))
        }
        #endif
    }

    // MARK: - Helpers

    private func makeService(kind: Kind, accountID: Account.ID) -> String {
        // Percent-encode accountID чтобы исключить коллизии при спецсимволах
        // (точки, слеши, etc.) в идентификаторе аккаунта.
        let safeID = accountID.rawValue
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? accountID.rawValue
        return "\(servicePrefix).\(safeID).\(kind.rawValue)"
    }

    #if canImport(Security)
    private func reason(for status: OSStatus) -> MailError.Reason {
        switch status {
        case errSecAuthFailed, errSecUserCanceled: return .invalidCredentials
        case errSecInteractionNotAllowed:          return .serverRejected
        default:                                   return .unknown
        }
    }
    #endif
}
