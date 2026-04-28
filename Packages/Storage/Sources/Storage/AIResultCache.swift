import Foundation
import GRDB
import Core

/// Кеш AI-результатов классификации/суммаризации.
///
/// Хранит в таблице `ai_cache` (SchemaV4):
/// - summary письма
/// - category (строка)
/// - tone (строка)
/// - language (ISO 639-1)
///
/// TTL: 7 дней. Устаревшие записи удаляются при GC.
///
/// Приватность: в `result_json` хранятся только AI-вычисленные метки,
/// не сырое тело письма.
public actor AIResultCache {
    public let pool: DatabasePool

    /// Семь дней — стандартный TTL для AI-результатов.
    public static let defaultTTL: TimeInterval = 7 * 24 * 3600

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Classification Cache

    /// Возвращает закешированный результат классификации для данного messageID.
    /// `nil`, если запись не найдена или истёк TTL.
    public func classificationResult(for messageID: String) async throws -> CachedClassification? {
        let now = Date()
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM ai_cache
                WHERE feature = 'classification' AND cache_key = ? AND expires_at > ?
                """, arguments: [messageID, now])
            else { return nil }
            let json: String = row["result_json"]
            return try Self.decodeClassification(json)
        }
    }

    /// Сохраняет результат классификации для данного messageID.
    public func storeClassification(
        _ result: CachedClassification,
        for messageID: String,
        ttl: TimeInterval = defaultTTL,
        now: Date = Date()
    ) async throws {
        let json = try Self.encodeClassification(result)
        let expiresAt = now.addingTimeInterval(ttl)
        let id = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO ai_cache (id, feature, cache_key, result_json, created_at, expires_at)
                VALUES (?, 'classification', ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [id, messageID, json, now, expiresAt])
            // Upsert по (feature, cache_key) — обновляем существующую запись если она есть
            try db.execute(sql: """
                UPDATE ai_cache
                SET result_json = ?, created_at = ?, expires_at = ?
                WHERE feature = 'classification' AND cache_key = ?
                """, arguments: [json, now, expiresAt, messageID])
        }
    }

    // MARK: - Summary Cache

    /// Возвращает закешированный summary для данного messageID.
    public func summary(for messageID: String) async throws -> String? {
        let now = Date()
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM ai_cache
                WHERE feature = 'summary' AND cache_key = ? AND expires_at > ?
                """, arguments: [messageID, now])
            else { return nil }
            return row["result_json"] as String?
        }
    }

    /// Сохраняет summary для данного messageID.
    public func storeSummary(
        _ summary: String,
        for messageID: String,
        ttl: TimeInterval = defaultTTL,
        now: Date = Date()
    ) async throws {
        let expiresAt = now.addingTimeInterval(ttl)
        let id = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO ai_cache (id, feature, cache_key, result_json, created_at, expires_at)
                VALUES (?, 'summary', ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [id, messageID, summary, now, expiresAt])
            try db.execute(sql: """
                UPDATE ai_cache
                SET result_json = ?, created_at = ?, expires_at = ?
                WHERE feature = 'summary' AND cache_key = ?
                """, arguments: [summary, now, expiresAt, messageID])
        }
    }

    // MARK: - Quick Reply Cache

    /// Возвращает закешированные варианты быстрых ответов для данного messageID.
    public func quickReplies(for messageID: String) async throws -> [String]? {
        let now = Date()
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM ai_cache
                WHERE feature = 'quick_reply' AND cache_key = ? AND expires_at > ?
                """, arguments: [messageID, now])
            else { return nil }
            let json: String = row["result_json"]
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }
    }

    /// Сохраняет варианты быстрых ответов для данного messageID.
    public func storeQuickReplies(
        _ replies: [String],
        for messageID: String,
        ttl: TimeInterval = defaultTTL,
        now: Date = Date()
    ) async throws {
        let data = try JSONEncoder().encode(replies)
        guard let json = String(data: data, encoding: .utf8) else { return }
        let expiresAt = now.addingTimeInterval(ttl)
        let id = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO ai_cache (id, feature, cache_key, result_json, created_at, expires_at)
                VALUES (?, 'quick_reply', ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [id, messageID, json, now, expiresAt])
            try db.execute(sql: """
                UPDATE ai_cache
                SET result_json = ?, created_at = ?, expires_at = ?
                WHERE feature = 'quick_reply' AND cache_key = ?
                """, arguments: [json, now, expiresAt, messageID])
        }
    }

    // MARK: - Invalidation

    /// Инвалидирует все кеш-записи для данного messageID (все фичи).
    public func invalidate(messageID: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM ai_cache WHERE cache_key = ?
                """, arguments: [messageID])
        }
    }

    // MARK: - GC

    /// Удаляет истёкшие записи. Возвращает количество удалённых строк.
    @discardableResult
    public func runGC(now: Date = Date()) async throws -> Int {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM ai_cache WHERE expires_at <= ?", arguments: [now])
            return db.changesCount
        }
    }

    // MARK: - Private

    private static func encodeClassification(_ result: CachedClassification) throws -> String {
        let data = try JSONEncoder().encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AIResultCacheError.encodingFailed
        }
        return json
    }

    private static func decodeClassification(_ json: String) throws -> CachedClassification {
        guard let data = json.data(using: .utf8) else {
            throw AIResultCacheError.decodingFailed
        }
        return try JSONDecoder().decode(CachedClassification.self, from: data)
    }
}

// MARK: - Data Types

/// Закешированный результат классификации письма (AI-метки, не тело).
public struct CachedClassification: Sendable, Codable, Equatable {
    /// Краткое резюме письма, сгенерированное AI.
    public let summary: String?
    /// Категория письма (work, finance, social, etc.).
    public let category: String?
    /// Тон письма (positive, neutral, negative, urgent).
    public let tone: String?
    /// Язык письма (ISO 639-1, например "en", "ru").
    public let language: String?

    public init(
        summary: String? = nil,
        category: String? = nil,
        tone: String? = nil,
        language: String? = nil
    ) {
        self.summary = summary
        self.category = category
        self.tone = tone
        self.language = language
    }
}

public enum AIResultCacheError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
}
