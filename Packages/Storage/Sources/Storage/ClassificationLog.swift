import Foundation
import GRDB
import Core

public struct ClassificationStats: Sendable, Equatable {
    public let totalRequests: Int
    public let tokensIn: Int
    public let tokensOut: Int
    public let failures: Int
}

/// Append-only лог классификаций. Телеметрия без PII.
public actor ClassificationLog {
    public let pool: DatabasePool

    public init(pool: DatabasePool) { self.pool = pool }

    public func append(_ entry: AuditEntry) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO classification_log
                    (id, message_id_hash, model, tokens_in, tokens_out,
                     duration_ms, confidence, matched_rule_id, error_code, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    entry.id.uuidString, entry.messageIdHash, entry.model,
                    entry.tokensIn, entry.tokensOut, entry.durationMs,
                    entry.confidence, entry.matchedRuleId?.uuidString,
                    entry.errorCode, entry.createdAt
                ]
            )
        }
    }

    public func recent(limit: Int = 50) async throws -> [AuditEntry] {
        try await pool.read { db in
            try Row.fetchAll(db,
                sql: "SELECT * FROM classification_log ORDER BY created_at DESC LIMIT ?",
                arguments: [limit]
            ).compactMap(Self.decode)
        }
    }

    public func monthStats(now: Date = Date()) async throws -> ClassificationStats {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        return try await pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS total,
                    COALESCE(SUM(tokens_in), 0) AS tokens_in,
                    COALESCE(SUM(tokens_out), 0) AS tokens_out,
                    SUM(CASE WHEN error_code IS NOT NULL THEN 1 ELSE 0 END) AS failures
                FROM classification_log
                WHERE created_at >= ?
                """, arguments: [cutoff])
            return ClassificationStats(
                totalRequests: (row?["total"] as Int?) ?? 0,
                tokensIn: (row?["tokens_in"] as Int?) ?? 0,
                tokensOut: (row?["tokens_out"] as Int?) ?? 0,
                failures: (row?["failures"] as Int?) ?? 0
            )
        }
    }

    /// Удаляет записи старше `days` дней. Возвращает количество удалённых строк.
    public func runRetentionGC(olderThanDays days: Int = 90, now: Date = Date()) async throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return try await pool.write { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM classification_log") ?? 0
            try db.execute(sql: "DELETE FROM classification_log WHERE created_at < ?", arguments: [cutoff])
            let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM classification_log") ?? 0
            return before - after
        }
    }

    private static func decode(_ row: Row) -> AuditEntry? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let matched: UUID? = (row["matched_rule_id"] as String?).flatMap(UUID.init(uuidString:))
        return AuditEntry(
            id: id,
            messageIdHash: row["message_id_hash"],
            model: row["model"],
            tokensIn: row["tokens_in"],
            tokensOut: row["tokens_out"],
            durationMs: row["duration_ms"],
            confidence: row["confidence"],
            matchedRuleId: matched,
            errorCode: row["error_code"],
            createdAt: row["created_at"]
        )
    }
}
