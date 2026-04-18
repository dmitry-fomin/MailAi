import Foundation
import Core

/// Абстракция хранилища секретов. Реальная реализация — Keychain; для тестов
/// используем in-memory fake. Подробности — docs/Secrets.md.
public protocol SecretsStore: Sendable {
    func setPassword(_ password: String, forAccount accountID: Account.ID) async throws
    func password(forAccount accountID: Account.ID) async throws -> String?
    func deletePassword(forAccount accountID: Account.ID) async throws

    func setOpenRouterKey(_ key: String, forAccount accountID: Account.ID) async throws
    func openRouterKey(forAccount accountID: Account.ID) async throws -> String?
    func deleteOpenRouterKey(forAccount accountID: Account.ID) async throws
}

/// In-memory реализация для тестов и dev-режима. НЕ использовать в проде —
/// секреты живут только в памяти процесса.
public actor InMemorySecretsStore: SecretsStore {
    private var passwords: [Account.ID: String] = [:]
    private var openRouterKeys: [Account.ID: String] = [:]

    public init() {}

    public func setPassword(_ password: String, forAccount accountID: Account.ID) async throws {
        passwords[accountID] = password
    }

    public func password(forAccount accountID: Account.ID) async throws -> String? {
        passwords[accountID]
    }

    public func deletePassword(forAccount accountID: Account.ID) async throws {
        passwords.removeValue(forKey: accountID)
    }

    public func setOpenRouterKey(_ key: String, forAccount accountID: Account.ID) async throws {
        openRouterKeys[accountID] = key
    }

    public func openRouterKey(forAccount accountID: Account.ID) async throws -> String? {
        openRouterKeys[accountID]
    }

    public func deleteOpenRouterKey(forAccount accountID: Account.ID) async throws {
        openRouterKeys.removeValue(forKey: accountID)
    }
}
