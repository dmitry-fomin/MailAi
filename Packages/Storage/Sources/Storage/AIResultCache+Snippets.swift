import Foundation
import GRDB

/// Расширение AIResultCache для хранения AI-сниппетов писем.
/// Используется AISnippetGenerator (AI пакет) и MessageRowView через ViewModel.
///
/// feature = 'snippet', cache_key = messageID, TTL 7 дней.
extension AIResultCache {
    private static let snippetFeature = "snippet"

    /// Загружает кешированный AI-сниппет.
    public func aiSnippet(for messageID: String) async throws -> String? {
        let now = Date()
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM ai_cache
                WHERE feature = ? AND cache_key = ? AND expires_at > ?
                """, arguments: [AIResultCache.snippetFeature, messageID, now])
            else { return nil }
            return row["result_json"] as String?
        }
    }

    /// Сохраняет AI-сниппет для данного messageID.
    public func storeAISnippet(
        _ snippet: String,
        for messageID: String,
        ttl: TimeInterval = AIResultCache.defaultTTL,
        now: Date = Date()
    ) async throws {
        let expiresAt = now.addingTimeInterval(ttl)
        let rowID = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO ai_cache (id, feature, cache_key, result_json, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [rowID, AIResultCache.snippetFeature, messageID, snippet, now, expiresAt])
            try db.execute(sql: """
                UPDATE ai_cache
                SET result_json = ?, created_at = ?, expires_at = ?
                WHERE feature = ? AND cache_key = ?
                """, arguments: [snippet, now, expiresAt, AIResultCache.snippetFeature, messageID])
        }
    }
}
