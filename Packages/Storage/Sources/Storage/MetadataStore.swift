import Foundation
import Core

/// Локальное хранилище метаданных писем. НИКОГДА не сохраняет тела.
/// Реальная реализация — GRDB (после подключения зависимости), в MVP
/// оставлен in-memory actor, удовлетворяющий контракту для UI-потока.
public protocol MetadataStore: Sendable {
    func upsert(_ messages: [Message]) async throws
    func messages(in mailbox: Mailbox.ID, page: Page) async throws -> [Message]
    func delete(messageIDs: [Message.ID]) async throws
    /// Вернёт единичный `Message` по id, если он есть в store. Нужен
    /// Live-провайдеру, чтобы при запросе `body(for:)` найти `UID`+`Mailbox.ID`
    /// без повторного полного скана.
    func message(id: Message.ID) async throws -> Message?
    /// Обеспечивает наличие `Account`-записи (FK-родитель для mailbox).
    func upsert(_ account: Account) async throws
    /// Обеспечивает наличие `Mailbox`-записи (FK-родитель для message).
    func upsert(_ mailbox: Mailbox) async throws
}

public actor InMemoryMetadataStore: MetadataStore {
    private var byMailbox: [Mailbox.ID: [Message.ID: Message]] = [:]
    private var mailboxes: [Mailbox.ID: Mailbox] = [:]
    private var accounts: [Account.ID: Account] = [:]

    public init() {}

    public func upsert(_ account: Account) async throws {
        accounts[account.id] = account
    }

    public func upsert(_ mailbox: Mailbox) async throws {
        mailboxes[mailbox.id] = mailbox
    }

    public func upsert(_ messages: [Message]) async throws {
        for msg in messages {
            byMailbox[msg.mailboxID, default: [:]][msg.id] = msg
        }
    }

    public func messages(in mailbox: Mailbox.ID, page: Page) async throws -> [Message] {
        let all = (byMailbox[mailbox]?.values ?? [:].values)
            .sorted { $0.date > $1.date }
        let start = min(page.offset, all.count)
        let end = min(start + page.limit, all.count)
        return Array(all[start..<end])
    }

    public func delete(messageIDs: [Message.ID]) async throws {
        for (mailbox, dict) in byMailbox {
            var mutable = dict
            for id in messageIDs { mutable.removeValue(forKey: id) }
            byMailbox[mailbox] = mutable
        }
    }

    public func message(id: Message.ID) async throws -> Message? {
        for dict in byMailbox.values {
            if let found = dict[id] { return found }
        }
        return nil
    }
}
