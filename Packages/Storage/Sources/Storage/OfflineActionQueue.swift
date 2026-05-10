import Foundation
import Core
import GRDB

/// Тип действия из офлайн-очереди.
///
/// Хранится как строка в SQLite (`action_type`). Payload — JSON с параметрами
/// (например, targetMailboxID для move). Тела писем и их фрагменты не хранятся.
public enum OfflineActionType: String, Sendable, Codable {
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case delete
    case move
    case flag
    case unflag
    case archive
    case restore
}

/// Запись в офлайн-очереди.
public struct OfflineAction: Sendable, Identifiable {
    public let id: Int64
    public let messageID: Message.ID
    public let accountID: Account.ID
    public let actionType: OfflineActionType
    /// JSON-payload с доп. параметрами (например, `{"targetMailboxID":"INBOX"}`).
    public let payload: String
    public let createdAt: Date
    public var attemptCount: Int

    /// Декодирует targetMailboxID из payload для действий `move` и `restore`.
    public var targetMailboxID: Mailbox.ID? {
        guard let data = payload.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = dict["targetMailboxID"] else { return nil }
        return Mailbox.ID(rawValue: raw)
    }
}

/// Актор-очередь отложенных действий для офлайн-режима.
///
/// Персистирует ожидающие действия в SQLite (таблица `offline_action_queue`).
/// При восстановлении соединения применяет их в порядке FIFO.
/// Conflict resolution: последнее действие того же типа над одним письмом
/// заменяет предыдущее (DELETE + INSERT).
///
/// Тела писем и их фрагменты не хранятся — инвариант CLAUDE.md соблюдён.
public actor OfflineActionQueue {

    private let pool: DatabasePool

    // MARK: - Init

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Enqueue

    /// Ставит действие в очередь. Конфликт (тот же messageID + actionType)
    /// разрешается в пользу последнего — предыдущая запись удаляется.
    public func enqueue(
        messageID: Message.ID,
        accountID: Account.ID,
        action: OfflineActionType,
        payload: [String: String] = [:]
    ) throws {
        let payloadJSON: String
        if let data = try? JSONEncoder().encode(payload),
           let str = String(data: data, encoding: .utf8) {
            payloadJSON = str
        } else {
            payloadJSON = "{}"
        }

        try pool.write { db in
            // Conflict resolution: удаляем предыдущее действие того же типа
            // над тем же письмом, затем вставляем новое.
            try db.execute(
                sql: """
                    DELETE FROM offline_action_queue
                    WHERE message_id = ? AND account_id = ? AND action_type = ?
                    """,
                arguments: [messageID.rawValue, accountID.rawValue, action.rawValue]
            )
            try db.execute(
                sql: """
                    INSERT INTO offline_action_queue
                        (message_id, account_id, action_type, payload)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [messageID.rawValue, accountID.rawValue, action.rawValue, payloadJSON]
            )
        }
    }

    // MARK: - Drain

    /// Возвращает все ожидающие действия для аккаунта в порядке FIFO.
    public func pendingActions(for accountID: Account.ID) throws -> [OfflineAction] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, message_id, account_id, action_type, payload,
                           created_at, attempt_count
                    FROM offline_action_queue
                    WHERE account_id = ?
                    ORDER BY id ASC
                    """,
                arguments: [accountID.rawValue]
            )
            return rows.compactMap { row -> OfflineAction? in
                guard
                    let id = row["id"] as Int64?,
                    let msgRaw = row["message_id"] as String?,
                    let accRaw = row["account_id"] as String?,
                    let typeRaw = row["action_type"] as String?,
                    let actionType = OfflineActionType(rawValue: typeRaw)
                else { return nil }
                return OfflineAction(
                    id: id,
                    messageID: Message.ID(rawValue: msgRaw),
                    accountID: Account.ID(rawValue: accRaw),
                    actionType: actionType,
                    payload: row["payload"] as String? ?? "{}",
                    createdAt: row["created_at"] as Date? ?? Date(),
                    attemptCount: row["attempt_count"] as Int? ?? 0
                )
            }
        }
    }

    /// Удаляет успешно выполненное действие из очереди.
    public func remove(id: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM offline_action_queue WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Инкрементирует счётчик попыток для действия.
    public func incrementAttemptCount(id: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE offline_action_queue SET attempt_count = attempt_count + 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Удаляет все действия для аккаунта (например, при выходе из аккаунта).
    public func clear(for accountID: Account.ID) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM offline_action_queue WHERE account_id = ?",
                arguments: [accountID.rawValue]
            )
        }
    }

    /// Количество ожидающих действий для аккаунта.
    public func count(for accountID: Account.ID) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM offline_action_queue WHERE account_id = ?",
                arguments: [accountID.rawValue]
            ) ?? 0
        }
    }

    // MARK: - Apply

    /// Применяет все ожидающие действия для аккаунта через `MailActionsProvider`.
    ///
    /// Вызывается `AccountSessionModel` при восстановлении соединения.
    /// При ошибке действие остаётся в очереди (счётчик попыток растёт).
    /// Действия с `attemptCount >= maxAttempts` пропускаются и удаляются.
    public func applyPending(
        for accountID: Account.ID,
        actions: some MailActionsProvider,
        maxAttempts: Int = 3
    ) async {
        let pending: [OfflineAction]
        do {
            pending = try pendingActions(for: accountID)
        } catch {
            return
        }
        guard !pending.isEmpty else { return }

        for action in pending {
            // Удаляем исчерпавшие попытки.
            if action.attemptCount >= maxAttempts {
                try? remove(id: action.id)
                continue
            }

            let success: Bool
            do {
                switch action.actionType {
                case .markRead:
                    try await actions.setRead(true, messageID: action.messageID)
                    success = true
                case .markUnread:
                    try await actions.setRead(false, messageID: action.messageID)
                    success = true
                case .delete:
                    try await actions.delete(messageID: action.messageID)
                    success = true
                case .archive:
                    try await actions.archive(messageID: action.messageID)
                    success = true
                case .flag:
                    try await actions.setFlagged(true, messageID: action.messageID)
                    success = true
                case .unflag:
                    try await actions.setFlagged(false, messageID: action.messageID)
                    success = true
                case .move:
                    if let targetID = action.targetMailboxID {
                        try await actions.moveToMailbox(
                            messageID: action.messageID,
                            targetMailboxID: targetID
                        )
                        success = true
                    } else {
                        // Невалидный payload — удаляем без попытки.
                        try? remove(id: action.id)
                        continue
                    }
                case .restore:
                    if let targetID = action.targetMailboxID {
                        try await actions.restore(
                            messageIDs: [action.messageID],
                            to: targetID
                        )
                        success = true
                    } else {
                        try? remove(id: action.id)
                        continue
                    }
                }
            } catch {
                success = false
            }

            if success {
                try? remove(id: action.id)
            } else {
                try? incrementAttemptCount(id: action.id)
            }
        }
    }
}
