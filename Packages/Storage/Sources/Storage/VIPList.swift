import Foundation
import GRDB

// MARK: - VIPSender

/// Запись VIP-отправителя в SQLite.
public struct VIPSender: Sendable, Equatable, Identifiable {
    /// Email-адрес в нижнем регистре.
    public let email: String
    /// Отображаемое имя (из последнего письма или введённое вручную).
    public let displayName: String?
    /// Дата добавления в VIP-список.
    public let addedAt: Date

    public var id: String { email }

    public init(email: String, displayName: String? = nil, addedAt: Date = Date()) {
        self.email = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName
        self.addedAt = addedAt
    }
}

// MARK: - VIPList

/// Актор для управления VIP-списком отправителей.
///
/// Хранит email-адреса VIP-отправителей в SQLite (таблица `vip_sender`).
/// Письма от VIP-отправителей должны:
/// - Всегда показываться в VIP Inbox.
/// - Не подавляться правилами фильтрации.
/// - Генерировать уведомления независимо от классификации.
///
/// Является синглтоном через `DatabaseQueue`, переданный при инициализации.
public actor VIPList {

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Query

    /// Возвращает все VIP-адреса.
    public func all() async throws -> [VIPSender] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT email, display_name, added_at
                FROM vip_sender
                ORDER BY added_at DESC
                """)
            return rows.map { row in
                let addedAtString: String = row["added_at"]
                let addedAt = Self.parseDate(addedAtString) ?? Date()
                return VIPSender(
                    email: row["email"],
                    displayName: row["display_name"],
                    addedAt: addedAt
                )
            }
        }
    }

    /// Проверяет, является ли адрес VIP.
    ///
    /// - Parameter email: Email-адрес (регистр не важен).
    /// - Returns: `true`, если адрес в VIP-списке.
    public func isVIP(email: String) async throws -> Bool {
        let normalised = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return try await dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM vip_sender WHERE email = ?
                """, arguments: [normalised]) ?? 0
            return count > 0
        }
    }

    /// Возвращает сет всех VIP email-адресов (для быстрой проверки in-memory).
    public func allEmails() async throws -> Set<String> {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT email FROM vip_sender")
            return Set(rows.map { row in row["email"] as String })
        }
    }

    // MARK: - Mutations

    /// Добавляет отправителя в VIP-список.
    ///
    /// Если адрес уже есть — обновляет `display_name` (INSERT OR REPLACE).
    ///
    /// - Parameters:
    ///   - email: Email-адрес.
    ///   - displayName: Отображаемое имя (опционально).
    public func add(email: String, displayName: String? = nil) async throws {
        let normalised = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return }

        let dateString = Self.formatDate(Date())
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO vip_sender (email, display_name, added_at)
                VALUES (?, ?, ?)
                """, arguments: [normalised, displayName, dateString])
        }
    }

    /// Удаляет отправителя из VIP-списка.
    ///
    /// - Parameter email: Email-адрес (регистр не важен).
    public func remove(email: String) async throws {
        let normalised = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        try await dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM vip_sender WHERE email = ?
                """, arguments: [normalised])
        }
    }

    /// Удаляет все VIP-адреса.
    public func removeAll() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vip_sender")
        }
    }

    // MARK: - Date Helpers

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private static let sqliteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        sqliteDateFormatter.string(from: date)
    }

    private static func parseDate(_ string: String) -> Date? {
        sqliteDateFormatter.date(from: string) ?? iso8601.date(from: string)
    }
}
