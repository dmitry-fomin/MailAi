import Foundation
import Core

/// Абстракция хранилища секретов. Реальная реализация — Keychain; для тестов
/// используем in-memory fake. Подробности — docs/Secrets.md.
public protocol SecretsStore: Sendable {
    func setPassword(_ password: String, forAccount accountID: Account.ID) async throws
    func password(forAccount accountID: Account.ID) async throws -> String?
    func deletePassword(forAccount accountID: Account.ID) async throws
}

/// In-memory реализация для тестов и dev-режима. НЕ использовать в проде —
/// секреты живут только в памяти процесса.
public actor InMemorySecretsStore: SecretsStore {
    private var storage: [Account.ID: String] = [:]

    public init() {}

    public func setPassword(_ password: String, forAccount accountID: Account.ID) async throws {
        storage[accountID] = password
    }

    public func password(forAccount accountID: Account.ID) async throws -> String? {
        storage[accountID]
    }

    public func deletePassword(forAccount accountID: Account.ID) async throws {
        storage.removeValue(forKey: accountID)
    }
}
