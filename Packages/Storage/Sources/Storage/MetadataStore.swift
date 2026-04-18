import Foundation
import Core

/// Локальное хранилище метаданных писем. НИКОГДА не сохраняет тела.
/// Реальная реализация — GRDB (после подключения зависимости), в MVP
/// оставлен in-memory actor, удовлетворяющий контракту для UI-потока.
public protocol MetadataStore: Sendable {
    func upsert(_ messages: [Message]) async throws
    func messages(in mailbox: Mailbox.ID, page: Page) async throws -> [Message]
    func delete(messageIDs: [Message.ID]) async throws
}

public actor InMemoryMetadataStore: MetadataStore {
    private var byMailbox: [Mailbox.ID: [Message.ID: Message]] = [:]

    public init() {}

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
}
