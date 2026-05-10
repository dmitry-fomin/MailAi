import Foundation
import GRDB

// MARK: - SnoozedMessage

/// Запись snoozed-письма из таблицы `snoozed_messages`.
public struct SnoozedMessage: Sendable, Equatable {
    /// Идентификатор письма.
    public let messageID: String
    /// Время возврата письма в inbox.
    public let snoozeUntil: Date
    /// Оригинальный mailbox (для перемещения обратно).
    public let originalMailboxID: String
    /// Когда было поставлено на snooze.
    public let createdAt: Date

    public init(
        messageID: String,
        snoozeUntil: Date,
        originalMailboxID: String,
        createdAt: Date = Date()
    ) {
        self.messageID = messageID
        self.snoozeUntil = snoozeUntil
        self.originalMailboxID = originalMailboxID
        self.createdAt = createdAt
    }
}

// MARK: - SnoozeScheduler

/// Актор для управления snooze-письмами.
///
/// Хранит расписание snooze в SQLite (`snoozed_messages`).
/// Проверку просроченных snooze следует вызывать из `BackgroundSyncCoordinator`
/// при каждом polling-цикле (раз в 5 минут).
///
/// Схема таблицы создана в `SchemaV4` (`v4c: snoozed_messages`):
/// - `message_id` PRIMARY KEY
/// - `snooze_until` DATETIME
/// - `original_mailbox_id`
/// - `created_at` DATETIME
public actor SnoozeScheduler {

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Snooze

    /// Добавляет письмо в snooze.
    ///
    /// Если письмо уже snoozed — перезаписывает время возврата.
    ///
    /// - Parameters:
    ///   - messageID: Идентификатор письма.
    ///   - until: Время возврата.
    ///   - originalMailboxID: Папка, из которой письмо было snoozed.
    public func snooze(messageID: String, until: Date, originalMailboxID: String) async throws {
        let nowString = formatDate(Date())
        let untilString = formatDate(until)

        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO snoozed_messages
                    (message_id, snooze_until, original_mailbox_id, created_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [messageID, untilString, originalMailboxID, nowString])
        }
    }

    // MARK: - Cancel Snooze

    /// Отменяет snooze для письма (удаляет из расписания без перемещения).
    public func cancelSnooze(messageID: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM snoozed_messages WHERE message_id = ?
                """, arguments: [messageID])
        }
    }

    // MARK: - Check Due

    /// Возвращает письма, у которых `snooze_until <= now`.
    ///
    /// После вызова caller должен:
    /// 1. Переместить письма обратно в `originalMailboxID`.
    /// 2. Вызвать `markDone(messageIDs:)` для удаления из таблицы.
    ///
    /// - Parameter now: Точка отсчёта (по умолчанию — текущее время).
    /// - Returns: Массив просроченных snooze-записей.
    public func dueMessages(at now: Date = Date()) async throws -> [SnoozedMessage] {
        let nowString = formatDate(now)

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT message_id, snooze_until, original_mailbox_id, created_at
                FROM snoozed_messages
                WHERE snooze_until <= ?
                ORDER BY snooze_until ASC
                """, arguments: [nowString])

            return rows.map { row in
                SnoozedMessage(
                    messageID: row["message_id"],
                    snoozeUntil: Self.parseDate(row["snooze_until"] as String) ?? now,
                    originalMailboxID: row["original_mailbox_id"],
                    createdAt: Self.parseDate(row["created_at"] as String) ?? now
                )
            }
        }
    }

    // MARK: - Mark Done

    /// Удаляет записи из таблицы после успешного возврата писем в inbox.
    public func markDone(messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }

        try await dbQueue.write { db in
            // SQLite ограничение на количество переменных — разбиваем на чанки по 100.
            for chunk in messageIDs.chunked(by: 100) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let args = StatementArguments(chunk)
                try db.execute(
                    sql: "DELETE FROM snoozed_messages WHERE message_id IN (\(placeholders))",
                    arguments: args
                )
            }
        }
    }

    // MARK: - Query

    /// Возвращает snooze-время для конкретного письма (nil — письмо не snoozed).
    public func snoozeTime(for messageID: String) async throws -> Date? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT snooze_until FROM snoozed_messages WHERE message_id = ?
                """, arguments: [messageID]) else { return nil }
            let dateString: String = row["snooze_until"]
            return Self.parseDate(dateString)
        }
    }

    /// Возвращает все активные snooze-записи (для UI).
    public func allSnoozed() async throws -> [SnoozedMessage] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT message_id, snooze_until, original_mailbox_id, created_at
                FROM snoozed_messages
                ORDER BY snooze_until ASC
                """)
            return rows.map { row in
                SnoozedMessage(
                    messageID: row["message_id"],
                    snoozeUntil: Self.parseDate(row["snooze_until"] as String) ?? Date(),
                    originalMailboxID: row["original_mailbox_id"],
                    createdAt: Self.parseDate(row["created_at"] as String) ?? Date()
                )
            }
        }
    }

    // MARK: - Date Helpers

    nonisolated private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string)
    }
}

// MARK: - Array + chunked

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
