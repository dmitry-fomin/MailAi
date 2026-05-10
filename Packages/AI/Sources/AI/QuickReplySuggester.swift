import Foundation
import Core
import Storage

// MARK: - Public Types

/// Тон ответа для генерации вариантов.
public enum ReplyTone: String, Sendable, Hashable, CaseIterable {
    case formal
    case friendly
    case concise
}

/// Один вариант быстрого ответа.
public struct ReplySuggestion: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let tone: ReplyTone

    public init(id: UUID = UUID(), text: String, tone: ReplyTone) {
        self.id = id
        self.text = text
        self.tone = tone
    }
}

/// Опциональный стиль письма пользователя.
/// Передаётся в промпт как style guide при интеграции с Smart Reply Templates (MailAi-fbf).
public struct WritingStyle: Sendable, Equatable {
    /// Краткое описание стиля, например "professional and brief" или "friendly, uses emojis".
    public let description: String
    /// Примеры фраз пользователя (не более 3).
    public let examples: [String]

    public init(description: String, examples: [String] = []) {
        self.description = description
        self.examples = Array(examples.prefix(3))
    }
}

// MARK: - Protocol

/// Абстракция генератора быстрых ответов. Позволяет мокировать в тестах.
public protocol AIQuickReplier: Actor {
    /// Генерирует 3 варианта ответа для данного письма.
    /// - Parameters:
    ///   - body: Текст письма (только в памяти, не сохраняется на диск).
    ///   - messageID: ID письма — для кеширования результата.
    ///   - tone: Желаемый тон ответов.
    ///   - style: Опциональный стиль пользователя (для интеграции с AI-R).
    func suggestReplies(
        body: String,
        messageID: Message.ID,
        tone: ReplyTone,
        style: WritingStyle?
    ) async throws -> [ReplySuggestion]
}

// MARK: - Implementation

/// Актор генерации коротких вариантов ответа.
///
/// По тексту письма генерирует 3 коротких варианта ответа (≤ 20 слов каждый).
/// Результат кешируется через `AIResultCache` по ключу `messageID + tone`.
/// Тело письма живёт только в памяти и не пишется на диск.
public actor QuickReplySuggester: AIQuickReplier {
    public let provider: any AIProvider
    public let model: String
    public let cache: AIResultCache

    public init(provider: any AIProvider, model: String, cache: AIResultCache) {
        self.provider = provider
        self.model = model
        self.cache = cache
    }

    public func suggestReplies(
        body: String,
        messageID: Message.ID,
        tone: ReplyTone = .concise,
        style: WritingStyle? = nil
    ) async throws -> [ReplySuggestion] {
        // Ключ кеша включает тон, чтобы разные тоны хранились отдельно
        let cacheKey = "\(messageID.rawValue):\(tone.rawValue)"

        // Проверяем кеш
        if let cached = try await cache.quickReplies(for: cacheKey) {
            return cached.enumerated().map { idx, text in
                ReplySuggestion(text: text, tone: tone)
            }
        }

        // Генерируем через OpenRouter
        let system = buildSystemPrompt(tone: tone, style: style)
        let user = buildUserPrompt(body: body)

        var buffer = ""
        for try await chunk in provider.complete(
            system: system,
            user: user,
            streaming: false,
            maxTokens: 300
        ) {
            buffer += chunk
        }

        guard !buffer.isEmpty else {
            throw QuickReplySuggesterError.emptyResponse
        }

        let suggestions = try parseReplies(buffer, tone: tone)

        // Кешируем результат (тексты без метаданных тона)
        let texts = suggestions.map { $0.text }
        try await cache.storeQuickReplies(texts, for: cacheKey)

        return suggestions
    }

    // MARK: - Private

    private func buildSystemPrompt(tone: ReplyTone, style: WritingStyle?) -> String {
        let toneInstruction: String
        switch tone {
        case .formal:
            toneInstruction = "formal and professional"
        case .friendly:
            toneInstruction = "friendly and warm"
        case .concise:
            toneInstruction = "brief and to the point"
        }

        var styleSection = ""
        if let style {
            styleSection = "\n\nUser's writing style: \(style.description)"
            if !style.examples.isEmpty {
                let exampleList = style.examples.map { "- \($0)" }.joined(separator: "\n")
                styleSection += "\nStyle examples:\n\(exampleList)"
            }
        }

        return """
            You are an email reply assistant. Generate exactly 3 short reply options.

            Requirements:
            - Each reply must be 20 words or fewer.
            - Tone: \(toneInstruction).
            - Replies must be distinct in intent (e.g., accept, decline, ask clarification, acknowledge).
            - Do NOT include greetings or sign-offs — just the core message.\(styleSection)

            Respond strictly in JSON:
            {
              "replies": [
                "Reply option 1",
                "Reply option 2",
                "Reply option 3"
              ]
            }
            """
    }

    private func buildUserPrompt(body: String) -> String {
        // Ограничиваем тело до 1500 символов — достаточно для контекста,
        // минимизируем токены и гарантируем, что тело не хранится.
        let truncated = String(body.prefix(1_500))
        return "Email to reply to:\n\(truncated)"
    }

    private func parseReplies(_ text: String, tone: ReplyTone) throws -> [ReplySuggestion] {
        let json = Classifier.extractJSONObject(text)
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RepliesResponse.self, from: data)
        else {
            throw QuickReplySuggesterError.malformedResponse(text)
        }

        let replies = decoded.replies.prefix(3).map { replyText -> ReplySuggestion in
            // Усекаем до 20 слов на случай, если модель нарушила ограничение
            let words = replyText.split(separator: " ", omittingEmptySubsequences: true)
            let truncated = words.prefix(20).joined(separator: " ")
            return ReplySuggestion(text: truncated, tone: tone)
        }

        guard !replies.isEmpty else {
            throw QuickReplySuggesterError.emptyResponse
        }

        return Array(replies)
    }

    private struct RepliesResponse: Decodable {
        let replies: [String]
    }
}

// MARK: - Errors

public enum QuickReplySuggesterError: Error, Equatable, Sendable {
    case emptyResponse
    case malformedResponse(String)
}
