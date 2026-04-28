import Foundation
import Core
import Storage

// MARK: - Public Types

/// Длина предложений в стиле пользователя.
public enum SentenceLength: String, Sendable, Equatable, Codable {
    case short
    case medium
    case long
}

/// Уровень формальности стиля.
public enum FormalityLevel: String, Sendable, Equatable, Codable {
    case formal
    case casual
    case mixed
}

/// Расширенный профиль стиля письма пользователя.
/// Используется как style guide в Quick Reply и Draft Coach.
public struct ExtendedWritingStyle: Sendable, Equatable, Codable {
    /// Стандартное приветствие (например "Hi", "Dear").
    public let greeting: String?
    /// Стандартное завершение (например "Best regards", "Thanks").
    public let closing: String?
    /// Средняя длина предложений.
    public let avgSentenceLength: SentenceLength
    /// Уровень формальности.
    public let formality: FormalityLevel
    /// Частые фразы пользователя (до 10).
    public let commonPhrases: [String]
    /// Краткое описание стиля для промпта (совместим с WritingStyle из QuickReplySuggester).
    public let description: String

    public init(
        greeting: String? = nil,
        closing: String? = nil,
        avgSentenceLength: SentenceLength = .medium,
        formality: FormalityLevel = .mixed,
        commonPhrases: [String] = [],
        description: String
    ) {
        self.greeting = greeting
        self.closing = closing
        self.avgSentenceLength = avgSentenceLength
        self.formality = formality
        self.commonPhrases = Array(commonPhrases.prefix(10))
        self.description = description
    }

    /// Конвертирует в базовый WritingStyle для совместимости с QuickReplySuggester.
    public func asWritingStyle() -> WritingStyle {
        WritingStyle(description: description, examples: Array(commonPhrases.prefix(3)))
    }
}

/// Персональный шаблон ответа.
public struct ReplyTemplate: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    /// Название шаблона (для отображения в UI).
    public let title: String
    /// Текст шаблона — может содержать плейсхолдеры вида {{name}}.
    public let body: String
    /// Шаблон создан на основе анализа истории (true) или является стандартным (false).
    public let isPersonalized: Bool
    /// Дата последнего обновления.
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        isPersonalized: Bool,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.isPersonalized = isPersonalized
        self.updatedAt = updatedAt
    }
}

// MARK: - Protocol

/// Абстракция анализатора стиля. Позволяет мокировать в тестах.
public protocol AIStyleAnalyzer: Actor {
    /// Анализирует исходящие письма и возвращает стиль пользователя.
    /// - Parameter sentMessages: Последние исходящие письма (только snippet, не тело целиком).
    func analyzeStyle(sentMessages: [MessageSummaryInput]) async throws -> ExtendedWritingStyle
}

// MARK: - SmartReplyTemplateStore

/// Актор хранилища персонализированных шаблонов ответов.
///
/// Анализирует историю исходящих писем через AI, строит стиль пользователя
/// и кеширует его в AIResultCache (feature='writing_style', TTL 7 дней).
///
/// Также хранит набор персональных шаблонов на основе стиля.
///
/// Приватность:
/// - В AI передаются только snippet-ы отправленных писем (до 300 символов).
/// - Полные тела писем на диск не пишутся.
/// - Стиль кешируется как AI-метаданные (не тело письма).
public actor SmartReplyTemplateStore: AIStyleAnalyzer {
    public let provider: any AIProvider
    public let cache: AIResultCache
    /// Максимум анализируемых исходящих писем.
    public static let maxSentMessages = 50

    /// Стандартные (не персонализированные) шаблоны.
    private static let standardTemplates: [ReplyTemplate] = [
        ReplyTemplate(
            title: "Подтверждение получения",
            body: "Спасибо, письмо получил(а). Рассмотрю и отвечу в ближайшее время.",
            isPersonalized: false
        ),
        ReplyTemplate(
            title: "Нужно время",
            body: "Добрый день! Нахожусь в командировке / занят(а). Отвечу, как только смогу.",
            isPersonalized: false
        ),
        ReplyTemplate(
            title: "Требуется уточнение",
            body: "Уточните, пожалуйста: {{вопрос}}.",
            isPersonalized: false
        )
    ]

    public init(provider: any AIProvider, cache: AIResultCache) {
        self.provider = provider
        self.cache = cache
    }

    // MARK: - Style Analysis

    public func analyzeStyle(sentMessages: [MessageSummaryInput]) async throws -> ExtendedWritingStyle {
        // Проверяем кеш
        if let cachedJSON = try? await cache.writingStyleJSON(),
           let data = cachedJSON.data(using: .utf8),
           let cached = try? JSONDecoder().decode(ExtendedWritingStyle.self, from: data) {
            return cached
        }

        let capped = Array(sentMessages.prefix(Self.maxSentMessages))
        guard !capped.isEmpty else {
            return defaultStyle()
        }

        let userPrompt = buildStylePrompt(messages: capped)
        var buffer = ""
        for try await chunk in provider.complete(
            system: Self.styleSystemPrompt,
            user: userPrompt,
            streaming: false,
            maxTokens: 400
        ) {
            buffer += chunk
        }

        guard !buffer.isEmpty else { return defaultStyle() }

        let style = parseStyle(buffer) ?? defaultStyle()
        // Кешируем на 7 дней
        if let data = try? JSONEncoder().encode(style),
           let json = String(data: data, encoding: .utf8) {
            try? await cache.storeWritingStyleJSON(json)
        }
        return style
    }

    // MARK: - Templates

    /// Возвращает все шаблоны: стандартные + персональные (если стиль доступен).
    public func templates(style: ExtendedWritingStyle?) -> [ReplyTemplate] {
        guard let style else { return Self.standardTemplates }
        let personalized = buildPersonalizedTemplates(style: style)
        return Self.standardTemplates + personalized
    }

    /// Инвалидирует кешированный стиль (для принудительного обновления).
    public func invalidateStyle() async throws {
        try await cache.invalidateWritingStyle()
    }


    // MARK: - Private

    private func buildPersonalizedTemplates(style: ExtendedWritingStyle) -> [ReplyTemplate] {
        var templates: [ReplyTemplate] = []

        let greeting = style.greeting.map { "\($0)! " } ?? ""
        let closing = style.closing.map { "\n\($0)." } ?? ""

        templates.append(ReplyTemplate(
            title: "Личный — Принято",
            body: "\(greeting)Принято, спасибо!\(closing)",
            isPersonalized: true
        ))

        templates.append(ReplyTemplate(
            title: "Личный — Уточнение",
            body: "\(greeting)Уточните, пожалуйста: {{вопрос}}\(closing)",
            isPersonalized: true
        ))

        if let phrase = style.commonPhrases.first {
            templates.append(ReplyTemplate(
                title: "Личный — Стиль",
                body: "\(greeting)\(phrase) — {{продолжение}}\(closing)",
                isPersonalized: true
            ))
        }

        return templates
    }

    private func buildStylePrompt(messages: [MessageSummaryInput]) -> String {
        let snippets = messages.prefix(20).enumerated().map { idx, msg in
            "[\(idx + 1)] From:\(msg.from) | \(msg.bodySnippet.prefix(300))"
        }.joined(separator: "\n")
        return "Sent messages (snippets only, analyze writing style):\n\(snippets)"
    }

    private func parseStyle(_ text: String) -> ExtendedWritingStyle? {
        let json = Classifier.extractJSONObject(text)
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StyleResponse.self, from: data)
        else { return nil }

        let sentenceLength = SentenceLength(rawValue: decoded.sentenceLength) ?? .medium
        let formality = FormalityLevel(rawValue: decoded.formality) ?? .mixed

        return ExtendedWritingStyle(
            greeting: decoded.greeting.nilIfEmpty,
            closing: decoded.closing.nilIfEmpty,
            avgSentenceLength: sentenceLength,
            formality: formality,
            commonPhrases: decoded.commonPhrases,
            description: decoded.description
        )
    }

    private func defaultStyle() -> ExtendedWritingStyle {
        ExtendedWritingStyle(
            avgSentenceLength: .medium,
            formality: .mixed,
            description: "neutral professional"
        )
    }

    // MARK: - Wire Types

    private struct StyleResponse: Decodable {
        let greeting: String
        let closing: String
        let sentenceLength: String
        let formality: String
        let commonPhrases: [String]
        let description: String

        enum CodingKeys: String, CodingKey {
            case greeting, closing, formality, description
            case sentenceLength = "sentence_length"
            case commonPhrases = "common_phrases"
        }
    }

    // MARK: - System Prompt

    private static let styleSystemPrompt = """
        Analyze the writing style of the email author based on these sent message snippets.

        Respond only with valid JSON:
        {
          "greeting": "most common opening word (e.g. Hi, Hello, Dear, or empty)",
          "closing": "most common sign-off (e.g. Best regards, Thanks, or empty)",
          "sentence_length": "short | medium | long",
          "formality": "formal | casual | mixed",
          "common_phrases": ["up to 10 characteristic phrases"],
          "description": "1 sentence describing the style for use as a prompt guide"
        }
        """
}

// MARK: - AIResultCache writing style helpers
// Методы расширения AIResultCache для кеширования стиля письма.
// Фактическая реализация находится в Storage пакете:
// Packages/Storage/Sources/Storage/AIResultCache+WritingStyle.swift


// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
