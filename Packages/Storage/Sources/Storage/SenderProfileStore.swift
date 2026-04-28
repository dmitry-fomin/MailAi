import Foundation
import GRDB
import Core

// MARK: - Public Types

/// Категория писем (для разбивки по типам, если AI-классификация включена).
public struct CategoryBreakdown: Sendable, Equatable, Codable {
    /// Категория (work, finance, social, etc.)
    public let category: String
    /// Число писем в категории.
    public let count: Int

    public init(category: String, count: Int) {
        self.category = category
        self.count = count
    }
}

/// Профиль отправителя, построенный на основе метаданных из БД.
///
/// Без AI-запросов: всё агрегируется локально.
/// topTopics — TF-IDF по темам писем (без токенов).
/// avgResponseHours — разница дат в тредах (при наличии thread_id).
public struct SenderProfile: Sendable, Equatable, Identifiable {
    /// Нормализованный email (нижний регистр) — уникальный идентификатор.
    public let id: String
    /// Отображаемое имя (последнее известное из метаданных).
    public let displayName: String?
    /// Всего писем от этого отправителя.
    public let totalMessages: Int
    /// Дата последнего письма.
    public let lastContactDate: Date?
    /// Среднее время ответа пользователя (часы). nil если данных нет или нет thread_id.
    public let avgResponseHours: Double?
    /// Топ-3 темы (из subject строк, локальный TF-IDF по словам).
    public let topTopics: [String]
    /// Суммарная важность (доля писем с importance=important).
    public let importanceScore: Double
    /// Разбивка по категориям (если AI-классификация включена).
    public let categoryBreakdown: [CategoryBreakdown]
    /// Пользователь пометил как VIP.
    public let isVIP: Bool

    public init(
        id: String,
        displayName: String? = nil,
        totalMessages: Int,
        lastContactDate: Date? = nil,
        avgResponseHours: Double? = nil,
        topTopics: [String] = [],
        importanceScore: Double = 0,
        categoryBreakdown: [CategoryBreakdown] = [],
        isVIP: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.totalMessages = totalMessages
        self.lastContactDate = lastContactDate
        self.avgResponseHours = avgResponseHours
        self.topTopics = Array(topTopics.prefix(3))
        self.importanceScore = max(0, min(1, importanceScore))
        self.categoryBreakdown = categoryBreakdown
        self.isVIP = isVIP
    }
}

// MARK: - SenderProfileStore

/// Актор контактной книги на основе метаданных БД.
///
/// Профили строятся on-the-fly из таблицы message — новых таблиц не добавляется.
/// VIP-статус кешируется в ai_cache (feature='sender_vip').
///
/// Ограничения:
/// - avgResponseHours требует наличия thread_id в схеме.
/// - categoryBreakdown заполняется только если AI-классификация (MailAi-d7i) включена.
public actor SenderProfileStore {
    public let pool: DatabasePool
    public let cache: AIResultCache

    public init(pool: DatabasePool, cache: AIResultCache) {
        self.pool = pool
        self.cache = cache
    }

    // MARK: - Public API

    /// Загружает профиль отправителя по email.
    public func profile(for email: String) async throws -> SenderProfile? {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }

        // Получаем метаданные из БД
        let stats = try await fetchStats(for: normalized)
        guard stats.totalMessages > 0 else { return nil }

        let topics = try await extractTopTopics(for: normalized)
        let avgResponse = try await computeAvgResponse(for: normalized)
        let categories = try await fetchCategories(for: normalized)
        let isVIP = await (try? fetchVIPStatus(for: normalized)) ?? false

        return SenderProfile(
            id: normalized,
            displayName: stats.displayName,
            totalMessages: stats.totalMessages,
            lastContactDate: stats.lastContactDate,
            avgResponseHours: avgResponse,
            topTopics: topics,
            importanceScore: stats.importanceScore,
            categoryBreakdown: categories,
            isVIP: isVIP
        )
    }

    /// Обновляет VIP-статус отправителя.
    public func setVIP(_ isVIP: Bool, for email: String) async throws {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        try await cache.storeSenderVIP(isVIP, for: normalized)
    }

    /// Возвращает топ-N самых активных отправителей.
    public func topSenders(limit: Int = 20) async throws -> [SenderProfile] {
        let emails = try await fetchTopSenderEmails(limit: limit)
        var profiles: [SenderProfile] = []
        for email in emails {
            if let profile = try await self.profile(for: email) {
                profiles.append(profile)
            }
        }
        return profiles
    }

    // MARK: - Private: DB Queries

    private struct SenderStats {
        let displayName: String?
        let totalMessages: Int
        let lastContactDate: Date?
        let importanceScore: Double
    }

    private func fetchStats(for email: String) async throws -> SenderStats {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                    from_name,
                    COUNT(*) AS total,
                    MAX(date) AS last_date,
                    SUM(CASE WHEN importance = 'important' THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS importance_score
                FROM message
                WHERE LOWER(from_address) = ?
                """, arguments: [email])
            else {
                return SenderStats(displayName: nil, totalMessages: 0, lastContactDate: nil, importanceScore: 0)
            }

            let total: Int = row["total"] ?? 0
            let displayName: String? = row["from_name"]
            let importanceScore: Double = row["importance_score"] ?? 0

            let lastDate: Date?
            if let dateStr: String = row["last_date"] {
                lastDate = ISO8601DateFormatter().date(from: dateStr)
            } else {
                lastDate = nil
            }

            return SenderStats(
                displayName: displayName.flatMap { $0.isEmpty ? nil : $0 },
                totalMessages: total,
                lastContactDate: lastDate,
                importanceScore: importanceScore
            )
        }
    }

    /// Извлекает топ-3 темы через упрощённый TF-IDF (считаем слова в subject).
    private func extractTopTopics(for email: String) async throws -> [String] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT subject FROM message
                WHERE LOWER(from_address) = ?
                ORDER BY date DESC
                LIMIT 100
                """, arguments: [email])

            var wordCount: [String: Int] = [:]
            let stopWords: Set<String> = ["re:", "fwd:", "fw:", "the", "a", "an", "in", "on",
                                          "at", "to", "for", "of", "and", "or", "is", "are",
                                          "was", "has", "have", "with", "от", "для", "по", "на",
                                          "из", "и", "в", "с", "к", "о", "не", "что", "это"]

            for row in rows {
                let subject: String = row["subject"] ?? ""
                let words = subject.lowercased()
                    .components(separatedBy: .init(charactersIn: " \t.,!?;:()[]{}<>\"'/\\"))
                    .filter { $0.count > 3 && !stopWords.contains($0) }
                for word in words {
                    wordCount[word, default: 0] += 1
                }
            }

            let sorted = wordCount.sorted { $0.value > $1.value }
            return Array(sorted.prefix(3).map { $0.key })
        }
    }

    /// Вычисляет среднее время ответа (часы) по тредам.
    private func computeAvgResponse(for email: String) async throws -> Double? {
        try await pool.read { db in
            // Ищем треды, где есть письмо от sender + ответ от нас
            // Упрощение: берём разницу между последующим письмом в треде
            let rows = try Row.fetchAll(db, sql: """
                SELECT m1.date AS sender_date, m2.date AS reply_date
                FROM message m1
                JOIN message m2 ON m1.thread_id = m2.thread_id
                    AND m2.date > m1.date
                WHERE LOWER(m1.from_address) = ?
                    AND m1.thread_id IS NOT NULL
                    AND m2.flags & 8 = 8  -- draft flag indicates our reply
                LIMIT 50
                """, arguments: [email])

            guard !rows.isEmpty else { return nil }

            var totalHours: Double = 0
            var count = 0
            let fmt = ISO8601DateFormatter()

            for row in rows {
                if let senderStr: String = row["sender_date"],
                   let replyStr: String = row["reply_date"],
                   let senderDate = fmt.date(from: senderStr),
                   let replyDate = fmt.date(from: replyStr) {
                    let hours = replyDate.timeIntervalSince(senderDate) / 3600
                    if hours > 0 && hours < 72 { // фильтруем аномалии
                        totalHours += hours
                        count += 1
                    }
                }
            }

            guard count > 0 else { return nil }
            return totalHours / Double(count)
        }
    }

    /// Загружает разбивку по категориям (если AI-классификация включена).
    private func fetchCategories(for email: String) async throws -> [CategoryBreakdown] {
        try await pool.read { db in
            // Проверяем, есть ли вообще данные классификации
            let rows = try Row.fetchAll(db, sql: """
                SELECT ac.result_json
                FROM ai_cache ac
                JOIN message m ON m.id = ac.cache_key
                WHERE ac.feature = 'classification'
                    AND LOWER(m.from_address) = ?
                LIMIT 100
                """, arguments: [email])

            guard !rows.isEmpty else { return [] }

            var categoryCount: [String: Int] = [:]
            for row in rows {
                if let json: String = row["result_json"],
                   let data = json.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(CategoryField.self, from: data),
                   let cat = parsed.category {
                    categoryCount[cat, default: 0] += 1
                }
            }

            return categoryCount
                .sorted { $0.value > $1.value }
                .map { CategoryBreakdown(category: $0.key, count: $0.value) }
        }
    }

    private struct CategoryField: Decodable {
        let category: String?
    }

    private func fetchVIPStatus(for email: String) async throws -> Bool {
        let json = try await cache.senderVIPJSON(for: email)
        return json == "true"
    }

    private func fetchTopSenderEmails(limit: Int) async throws -> [String] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT LOWER(from_address) AS email, COUNT(*) AS cnt
                FROM message
                WHERE from_address IS NOT NULL
                GROUP BY LOWER(from_address)
                ORDER BY cnt DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.compactMap { row in row["email"] as String? }
        }
    }
}

// MARK: - AIResultCache extension for sender VIP

extension AIResultCache {
    private static let senderVIPFeature = "sender_vip"

    public func senderVIPJSON(for email: String) async throws -> String? {
        let now = Date()
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM ai_cache
                WHERE feature = ? AND cache_key = ? AND expires_at > ?
                """, arguments: [AIResultCache.senderVIPFeature, email, now])
            else { return nil }
            return row["result_json"] as String?
        }
    }

    public func storeSenderVIP(
        _ isVIP: Bool,
        for email: String,
        ttl: TimeInterval = 365 * 24 * 3600, // 1 год
        now: Date = Date()
    ) async throws {
        let json = isVIP ? "true" : "false"
        let expiresAt = now.addingTimeInterval(ttl)
        let rowID = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO ai_cache (id, feature, cache_key, result_json, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [rowID, AIResultCache.senderVIPFeature, email, json, now, expiresAt])
            try db.execute(sql: """
                UPDATE ai_cache
                SET result_json = ?, created_at = ?, expires_at = ?
                WHERE feature = ? AND cache_key = ?
                """, arguments: [json, now, expiresAt, AIResultCache.senderVIPFeature, email])
        }
    }
}
