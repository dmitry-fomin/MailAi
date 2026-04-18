import Foundation
import GRDB
import Core

/// Репозиторий NL-правил пользователя в SQLite. Actor для изоляции.
public actor RulesRepository {
    public let pool: DatabasePool

    public init(pool: DatabasePool) { self.pool = pool }

    public func upsert(_ rule: Rule) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO rule (id, text, intent, enabled, created_at, source)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    text = excluded.text,
                    intent = excluded.intent,
                    enabled = excluded.enabled,
                    source = excluded.source
                """,
                arguments: [
                    rule.id.uuidString, rule.text, rule.intent.rawValue,
                    rule.enabled, rule.createdAt, rule.source.rawValue
                ]
            )
        }
    }

    public func delete(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM rule WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    public func setEnabled(id: UUID, enabled: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE rule SET enabled = ? WHERE id = ?",
                           arguments: [enabled, id.uuidString])
        }
    }

    public func all() async throws -> [Rule] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM rule ORDER BY created_at DESC")
                .compactMap(Self.decode)
        }
    }

    public func active() async throws -> [Rule] {
        try await pool.read { db in
            try Row.fetchAll(db,
                sql: "SELECT * FROM rule WHERE enabled = 1 ORDER BY created_at DESC"
            ).compactMap(Self.decode)
        }
    }

    private static func decode(_ row: Row) -> Rule? {
        guard let id = UUID(uuidString: row["id"]),
              let intent = Rule.Intent(rawValue: row["intent"]),
              let source = Rule.Source(rawValue: row["source"]) else {
            return nil
        }
        return Rule(
            id: id,
            text: row["text"],
            intent: intent,
            enabled: row["enabled"],
            createdAt: row["created_at"],
            source: source
        )
    }
}
