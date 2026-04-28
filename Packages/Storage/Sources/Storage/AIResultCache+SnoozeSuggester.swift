import Foundation
import GRDB

/// Расширение AIResultCache для хранения результатов AISnoozeSuggester.
/// Хранит сырой JSON — декодирование в SnoozeSuggestion выполняется в AI пакете.
///
/// feature = 'snooze', cache_key = messageID, TTL 24 часа.
extension AIResultCache {
    private static let snoozeFeature = "snooze"

    /// Загружает JSON результата snooze-предложения.
    /// nil — запись не найдена или истёк TTL.
    public func snoozeJSON(for messageID: String) async throws -> String? {
        let now = Date()
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM ai_cache
                WHERE feature = ? AND cache_key = ? AND expires_at > ?
                """, arguments: [AIResultCache.snoozeFeature, messageID, now])
            else { return nil }
            return row["result_json"] as String?
        }
    }

    /// Сохраняет JSON результата snooze-предложения.
    public func storeSnoozeJSON(
        _ json: String,
        for messageID: String,
        ttl: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) async throws {
        let expiresAt = now.addingTimeInterval(ttl)
        let rowID = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO ai_cache (id, feature, cache_key, result_json, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [rowID, AIResultCache.snoozeFeature, messageID, json, now, expiresAt])
            try db.execute(sql: """
                UPDATE ai_cache
                SET result_json = ?, created_at = ?, expires_at = ?
                WHERE feature = ? AND cache_key = ?
                """, arguments: [json, now, expiresAt, AIResultCache.snoozeFeature, messageID])
        }
    }
}
