import Foundation
import Core

/// AI-транслятор natural-language поисковых запросов → `ParsedSearchQuery`.
///
/// Принимает произвольный текст («письма от Ивана про бюджет за март»)
/// и через OpenRouter транслирует его в структурированные параметры IMAP SEARCH.
///
/// ## Приватность
/// - В AI уходит ТОЛЬКО сам запрос пользователя (текст строки поиска).
/// - Тела писем, адреса, вложения — НИКОГДА не передаются.
/// - Ответ не кешируется (каждый запрос уникален).
///
/// ## Использование
/// ```swift
/// let translator = NLSearchTranslator(provider: openRouterClient)
/// let parsed = try await translator.parse(query: "письма от шефа на прошлой неделе")
/// let queryString = parsed.toQueryString()  // "from:шеф after:2026-04-21 before:2026-04-28"
/// ```
public actor NLSearchTranslator: AINLQueryParser {

    // MARK: - Dependencies

    private let provider: any AIProvider
    private var cachedSystemPrompt: String?

    // MARK: - Init

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    // MARK: - AINLQueryParser

    /// Парсит NL-запрос через OpenRouter и возвращает `ParsedSearchQuery`.
    ///
    /// - Если AI вернул невалидный JSON или пустой объект — возвращает `ParsedSearchQuery()`.
    /// - Бросает ошибку только при сетевых/IO-проблемах.
    public func parse(query: String) async throws -> ParsedSearchQuery {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ParsedSearchQuery() }

        let system = try await resolveSystemPrompt()
        let user   = buildUserMessage(query: trimmed)

        // Используем non-streaming: ответ небольшой (JSON объект).
        var responseText = ""
        for try await chunk in provider.complete(
            system: system,
            user: user,
            streaming: false,
            maxTokens: 300
        ) {
            responseText += chunk
        }

        return parseJSON(responseText)
    }

    // MARK: - Private: Prompt

    /// Загружает системный промпт из `PromptStore` (с кешем в акторе).
    private func resolveSystemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }
        let base = try await PromptStore.shared.load(id: "nl_search")
        // Добавляем сегодняшнюю дату, чтобы AI мог считать относительные периоды.
        let today = Self.isoDate(Date())
        let prompt = base + "\n\nToday's date: \(today)"
        cachedSystemPrompt = prompt
        return prompt
    }

    private func buildUserMessage(query: String) -> String {
        "User query: \(query)"
    }

    // MARK: - Private: JSON parsing

    /// Разбирает JSON-ответ от AI в `ParsedSearchQuery`.
    /// При любой ошибке — возвращает пустой `ParsedSearchQuery()`.
    private func parseJSON(_ text: String) -> ParsedSearchQuery {
        // Извлекаем первый JSON-объект из текста (AI иногда добавляет markdown).
        guard let jsonString = extractJSON(from: text),
              let data = jsonString.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return ParsedSearchQuery()
        }

        var result = ParsedSearchQuery()
        result.from    = dict["from"]    as? String
        result.to      = dict["to"]      as? String
        result.subject = dict["subject"] as? String
        result.body    = dict["body"]    as? String
        result.hasAttachment = dict["hasAttachment"] as? Bool
        result.isUnread      = dict["isUnread"]      as? Bool

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        iso.timeZone = TimeZone(identifier: "UTC")

        if let sinceStr = dict["dateSince"] as? String {
            result.dateSince = iso.date(from: sinceStr)
        }
        if let beforeStr = dict["dateBefore"] as? String {
            result.dateBefore = iso.date(from: beforeStr)
        }

        return result
    }

    /// Ищет первый `{...}` в строке — устойчиво к markdown-оборачиванию.
    private func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end   = text.lastIndex(of: "}")
        else { return nil }
        guard start <= end else { return nil }
        return String(text[start...end])
    }

    // MARK: - Helpers

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func isoDate(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
