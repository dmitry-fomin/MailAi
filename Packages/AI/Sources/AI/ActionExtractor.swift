import Foundation
import Core

/// AI-экстрактор действий из тела письма.
/// Извлекает дедлайны, задачи, встречи, ссылки, вопросы.
///
/// Приватность:
/// - Отправка только по явному клику пользователя.
/// - Полное тело письма передаётся только в память, не сохраняется.
public actor ActionExtractor: AIActionExtractor {
    private let provider: any AIProvider
    private var cachedSystemPrompt: String?

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    /// Извлекает действия из тела письма.
    /// - Parameter body: Plain text тело (до 2000 символов используется).
    public func extract(body: String) async throws -> [ActionItem] {
        let snippet = String(body.prefix(2000))
        let system = try await resolveSystemPrompt()
        var fullResponse = ""
        for try await chunk in provider.complete(
            system: system,
            user: snippet,
            streaming: false,
            maxTokens: 600
        ) {
            fullResponse += chunk
        }
        return try parseResponse(fullResponse)
    }

    // MARK: - Private

    /// Загружает инструкцию из PromptStore (с кешированием) и склеивает с
    /// хардкоженым responseFormat. Разделение: инструкция живёт в .md и
    /// редактируется пользователем; формат JSON — в коде рядом с парсером.
    private func resolveSystemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }
        let instruction = try await PromptStore.shared.load(id: "extract_actions")
        let full = instruction + "\n\n" + Self.responseFormat
        cachedSystemPrompt = full
        return full
    }

    /// JSON-схема ответа. Парсится через `RawItem` / `JSONDecoder`.
    private static let responseFormat = """
        Respond only with valid JSON array, no markdown, no explanation:
        [{"kind": "deadline|task|meeting|link|question", "text": "description", "dueDate": "ISO8601 or null"}]
        Rules:
        - kind must be one of: deadline, task, meeting, link, question
        - dueDate: ISO8601 string if a date can be inferred, otherwise omit the field
        - Include only meaningful actions, not generic phrases
        """

    private func parseResponse(_ json: String) throws -> [ActionItem] {
        let cleaned = stripMarkdown(json)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode([RawItem].self, from: data)
        return decoded.compactMap { item in
            guard let kind = ActionKind(rawValue: item.kind) else { return nil }
            var dueDate: Date?
            if let dueDateStr = item.dueDate {
                dueDate = ISO8601DateFormatter().date(from: dueDateStr)
            }
            return ActionItem(
                id: UUID().uuidString,
                kind: kind,
                text: item.text,
                dueDate: dueDate
            )
        }
    }

    private func stripMarkdown(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            let lines = result.components(separatedBy: "\n")
            let inner = lines.dropFirst().dropLast()
            result = inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private struct RawItem: Decodable {
        let kind: String
        let text: String
        let dueDate: String?
    }
}
