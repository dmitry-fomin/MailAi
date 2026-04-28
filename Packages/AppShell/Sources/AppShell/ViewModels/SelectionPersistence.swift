import Foundation
import os
import Core

/// A8: персистентный выбор «последней открытой папки» по аккаунту. Хранится
/// в `UserDefaults`, чтобы при перезапуске приложения окно аккаунта
/// восстанавливало именно ту папку, где пользователь был.
///
/// Тела писем и метаданные сюда не попадают — только `Mailbox.ID`.
public protocol SelectionPersistence: Sendable {
    func selectedMailbox(for accountID: Account.ID) -> Mailbox.ID?
    func setSelectedMailbox(_ mailbox: Mailbox.ID?, for accountID: Account.ID)
}

public struct DefaultsSelectionPersistence: SelectionPersistence, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "MailAi.selectedMailbox."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(for accountID: Account.ID) -> String {
        keyPrefix + accountID.rawValue
    }

    public func selectedMailbox(for accountID: Account.ID) -> Mailbox.ID? {
        guard let raw = defaults.string(forKey: key(for: accountID)) else { return nil }
        return Mailbox.ID(raw)
    }

    public func setSelectedMailbox(_ mailbox: Mailbox.ID?, for accountID: Account.ID) {
        let k = key(for: accountID)
        if let mailbox {
            defaults.set(mailbox.rawValue, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }
}

public struct InMemorySelectionPersistence: SelectionPersistence {
    // БАГ-10: защищаем values через OSAllocatedUnfairLock, чтобы убрать
    // @unchecked Sendable без реальной синхронизации.
    private final class Storage: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[Account.ID: Mailbox.ID]>(initialState: [:])

        func get(for accountID: Account.ID) -> Mailbox.ID? {
            lock.withLock { $0[accountID] }
        }

        func set(_ mailbox: Mailbox.ID?, for accountID: Account.ID) {
            lock.withLock { values in
                if let mailbox {
                    values[accountID] = mailbox
                } else {
                    values.removeValue(forKey: accountID)
                }
            }
        }
    }
    private let storage = Storage()

    public init() {}

    public func selectedMailbox(for accountID: Account.ID) -> Mailbox.ID? {
        storage.get(for: accountID)
    }

    public func setSelectedMailbox(_ mailbox: Mailbox.ID?, for accountID: Account.ID) {
        storage.set(mailbox, for: accountID)
    }
}
