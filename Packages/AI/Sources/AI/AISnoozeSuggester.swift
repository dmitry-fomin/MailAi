import Foundation
import Core
import Storage

// MARK: - Public Types

/// Предложение времени snooze от AI.
public struct SnoozeSuggestion: Sendable, Equatable {
    /// Рекомендуемое время возврата письма.
    public let suggestedDate: Date
    /// Краткое объяснение (например «Встреча завтра в 14:00»).
    public let reason: String

    public init(suggestedDate: Date, reason: String) {
        self.suggestedDate = suggestedDate
        self.reason = reason
    }
}

// MARK: - Protocol

/// Абстракция AI-сервиса snooze-предложений. Позволяет мокировать в тестах.
public protocol AISnoozeSuggesterProtocol: Actor {
    /// Анализирует письмо и предлагает время snooze.
    ///
    /// Вызывается ТОЛЬКО по явному действию пользователя (открытие меню Snooze).
    ///
    /// - Parameters:
    ///   - subject: Тема письма.
    ///   - snippet: Фрагмент тела письма (до 500 символов).
    ///   - messageID: ID письма — для кеширования.
    /// - Returns: `SnoozeSuggestion` если AI нашёл дедлайн/событие, `nil` — нет.
    func suggest(
        subject: String,
        snippet: String,
        messageID: Message.ID
    ) async throws -> SnoozeSuggestion?
}

// MARK: - Implementation

/// Актор-суггестор времени snooze через OpenRouter.
///
/// Логика:
/// - Если в письме упоминается конкретный дедлайн или встреча с датой →
///   предлагает за 1 день до (или в 9:00 утра в день события, если дедлайн сегодня).
/// - Если конкретной даты нет → возвращает `nil` (UI покажет стандартные варианты).
///
/// Приватность:
/// - Передаётся только тема + snippet (не полное тело).
/// - Вызов ТОЛЬКО по явному действию пользователя.
/// - Результат кешируется на 24 часа в ai_cache.
public actor AISnoozeSuggester: AISnoozeSuggesterProtocol {
    public let provider: any AIProvider
    public let cache: AIResultCache

    /// TTL кеша: 24 часа (snooze-предложения теряют смысл быстро).
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    public init(provider: any AIProvider, cache: AIResultCache) {
        self.provider = provider
        self.cache = cache
    }

    public func suggest(
        subject: String,
        snippet: String,
        messageID: Message.ID
    ) async throws -> SnoozeSuggestion? {
        // Проверяем кеш.
        if let cached = try? await cachedSuggestion(for: messageID.rawValue) {
            return cached
        }

        let userPrompt = buildUserPrompt(subject: subject, snippet: snippet)

        var buffer = ""
        for try await chunk in provider.complete(
            system: Self.systemPrompt,
            user: userPrompt,
            streaming: false,
            maxTokens: 200
        ) {
            buffer += chunk
        }

        guard !buffer.isEmpty else { return nil }

        let suggestion = parseSuggestion(buffer)

        // Кешируем (включая nil — sentinel).
        try? await cacheSuggestion(suggestion, for: messageID.rawValue)

        return suggestion
    }

    // MARK: - Private: Prompt

    private func buildUserPrompt(subject: String, snippet: String) -> String {
        let trimmedSnippet = String(snippet.prefix(500))
        let nowString = ISO8601DateFormatter().string(from: Date())
        return """
            Current date/time: \(nowString)
            Subject: \(subject)
            Message snippet: \(trimmedSnippet)
            """
    }

    // MARK: - Private: Parsing

    private func parseSuggestion(_ text: String) -> SnoozeSuggestion? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "null" || trimmed == "{}" || trimmed.hasPrefix("{\"found\":false") {
            return nil
        }

        let jsonText = Classifier.extractJSONObject(text)
        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SnoozeResponse.self, from: data),
              decoded.found,
              !decoded.suggestedDate.isEmpty
        else { return nil }

        // Парсим ISO8601 дату.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]

        guard let date = iso.date(from: decoded.suggestedDate) ?? iso2.date(from: decoded.suggestedDate)
        else { return nil }

        // Не предлагать время в прошлом.
        guard date > Date() else { return nil }

        return SnoozeSuggestion(suggestedDate: date, reason: decoded.reason)
    }

    // MARK: - Wire Type

    private struct SnoozeResponse: Decodable {
        /// true — AI нашёл дедлайн/событие.
        let found: Bool
        /// ISO8601 дата рекомендуемого напоминания.
        let suggestedDate: String
        /// Краткое объяснение на языке письма.
        let reason: String

        enum CodingKeys: String, CodingKey {
            case found
            case suggestedDate = "suggested_date"
            case reason
        }
    }

    // MARK: - System Prompt

    /// Системный промпт: AI ищет дедлайны/события и возвращает JSON с датой напоминания.
    private static let systemPrompt = """
        You are a smart email snooze assistant. Analyze the email subject and snippet.

        Determine if the email mentions a specific deadline, meeting, event, or time-sensitive task.

        Rules:
        - If a specific date/deadline is found: suggest a reminder for 1 day before at 9:00 AM local time.
        - If the event/deadline is today or tomorrow: suggest reminder for 1 hour before (or 1 hour from now if time is unclear).
        - If NO specific date or deadline is found: return found=false.

        Respond ONLY with valid JSON, no markdown:
        {
          "found": true,
          "suggested_date": "ISO8601 datetime with timezone offset",
          "reason": "Brief explanation in the language of the email (max 60 chars)"
        }

        If no deadline found:
        {"found": false, "suggested_date": "", "reason": ""}

        Do not invent dates. Only use dates explicitly mentioned in the email.
        """
}

// MARK: - AISnoozeSuggester Cache Helpers
// AIResultCache.snoozeJSON / storeSnoozeJSON объявлены в
// Packages/Storage/Sources/Storage/AIResultCache+SnoozeSuggester.swift

extension AISnoozeSuggester {
    func cachedSuggestion(for messageID: String) async throws -> SnoozeSuggestion? {
        guard let json = try await cache.snoozeJSON(for: messageID) else { return nil }
        if json == "__null__" { return nil }
        guard let data = json.data(using: .utf8),
              let cached = try? JSONDecoder().decode(CachedSuggestion.self, from: data)
        else { return nil }
        return SnoozeSuggestion(suggestedDate: cached.suggestedDate, reason: cached.reason)
    }

    func cacheSuggestion(_ suggestion: SnoozeSuggestion?, for messageID: String) async throws {
        if let suggestion {
            let cached = CachedSuggestion(suggestedDate: suggestion.suggestedDate, reason: suggestion.reason)
            if let data = try? JSONEncoder().encode(cached),
               let json = String(data: data, encoding: .utf8) {
                try await cache.storeSnoozeJSON(json, for: messageID)
            }
        } else {
            try await cache.storeSnoozeJSON("__null__", for: messageID)
        }
    }

    private struct CachedSuggestion: Codable {
        let suggestedDate: Date
        let reason: String
    }
}
