import Foundation
import Core
import Storage

// MARK: - Protocol

/// Абстракция генератора AI-сниппетов для списка писем.
public protocol AISnippetGenerating: Actor {
    /// Генерирует однострочный AI-сниппет (до 80 символов).
    /// Результат кешируется в AIResultCache (feature='snippet').
    /// - Parameters:
    ///   - input: Метаданные письма для классификации.
    ///   - messageID: ID письма — ключ кеша.
    func generateSnippet(
        input: ClassificationInput,
        messageID: Message.ID
    ) async throws -> String
}

// MARK: - Implementation

/// Актор генерации AI-превью писем для MessageRowView.
///
/// Генерирует однострочный сниппет (≤ 80 символов) из темы и preview письма.
/// Результат кешируется в AIResultCache с feature='snippet', TTL 7 дней.
///
/// Вызывается через ClassificationQueue в фоне — пользователь видит
/// placeholder «...» пока сниппет генерируется.
///
/// Настройка: feature включается только при toggle 'AI-превью писем' (default off).
public actor AISnippetGenerator: AISnippetGenerating {
    public let provider: any AIProvider
    public let cache: AIResultCache

    public init(provider: any AIProvider, cache: AIResultCache) {
        self.provider = provider
        self.cache = cache
    }

    public func generateSnippet(
        input: ClassificationInput,
        messageID: Message.ID
    ) async throws -> String {
        // Проверяем кеш
        if let cached = try await cache.aiSnippet(for: messageID.rawValue) {
            return cached
        }

        let userPrompt = buildPrompt(input: input)

        var buffer = ""
        for try await chunk in provider.complete(
            system: Self.systemPrompt,
            user: userPrompt,
            streaming: false,
            maxTokens: 100
        ) {
            buffer += chunk
        }

        guard !buffer.isEmpty else { return "" }

        // Очищаем и усекаем до 80 символов
        let snippet = cleanSnippet(buffer)

        // Кешируем
        try? await cache.storeAISnippet(snippet, for: messageID.rawValue)

        return snippet
    }

    // MARK: - Private

    private func buildPrompt(input: ClassificationInput) -> String {
        var parts: [String] = []
        parts.append("Subject: \(input.subject)")
        if !input.from.isEmpty { parts.append("From: \(input.from)") }
        let body = input.bodySnippet.trimmingCharacters(in: .whitespaces)
        if !body.isEmpty {
            parts.append("Preview: \(String(body.prefix(300)))")
        }
        return parts.joined(separator: "\n")
    }

    private func cleanSnippet(_ text: String) -> String {
        // Убираем кавычки, markdown и лишние пробелы
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_"))
        // Берём первое предложение или усекаем до 80 символов
        let firstSentence = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .first?
            .trimmingCharacters(in: .whitespaces) ?? cleaned
        return String(firstSentence.prefix(80))
    }

    // MARK: - System Prompt

    private static let systemPrompt = """
        Generate a one-line summary (max 80 characters) of this email. Be concise and specific.
        Return ONLY the summary text, no quotes, no punctuation at the end, no explanation.
        Examples: "Invoice #1234 due next Friday", "Meeting rescheduled to Thursday 3pm", "Job offer from Acme Corp"
        """
}

// MARK: - AIResultCache snippet methods
// Определены в Storage пакете:
// Packages/Storage/Sources/Storage/AIResultCache+Snippets.swift

