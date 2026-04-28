import Foundation
import GRDB

/// Расширение AIResultCache для хранения стиля письма пользователя.
/// Используется SmartReplyTemplateStore (AI пакет).
///
/// feature = 'writing_style', cache_key = 'global:writing_style', TTL 7 дней.
/// Хранится JSON ExtendedWritingStyle — AI-метаданные, не тело письма.
extension AIResultCache {
    public static let writingStyleCacheKey = "global:writing_style"

    /// Загружает кешированный JSON стиля письма.
    /// Декодирование в ExtendedWritingStyle выполняется на стороне AI пакета.
    public func writingStyleJSON() async throws -> String? {
        let now = Date()
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM ai_cache
                WHERE feature = 'writing_style' AND cache_key = ? AND expires_at > ?
                """, arguments: [AIResultCache.writingStyleCacheKey, now])
            else { return nil }
            return row["result_json"] as String?
        }
    }

    /// Сохраняет JSON стиля письма (TTL 7 дней).
    public func storeWritingStyleJSON(
        _ json: String,
        ttl: TimeInterval = AIResultCache.defaultTTL,
        now: Date = Date()
    ) async throws {
        let expiresAt = now.addingTimeInterval(ttl)
        let rowID = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO ai_cache (id, feature, cache_key, result_json, created_at, expires_at)
                VALUES (?, 'writing_style', ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [rowID, AIResultCache.writingStyleCacheKey, json, now, expiresAt])
            try db.execute(sql: """
                UPDATE ai_cache
                SET result_json = ?, created_at = ?, expires_at = ?
                WHERE feature = 'writing_style' AND cache_key = ?
                """, arguments: [json, now, expiresAt, AIResultCache.writingStyleCacheKey])
        }
    }

    /// Удаляет кешированный стиль (для принудительного обновления).
    public func invalidateWritingStyle() async throws {
        try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM ai_cache WHERE feature = 'writing_style' AND cache_key = ?
                """, arguments: [AIResultCache.writingStyleCacheKey])
        }
    }
}
