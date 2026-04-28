import Foundation
import Core

public enum ClassifierError: Error, Equatable, Sendable {
    case emptyResponse
    case malformedJSON(String)
}

/// Классификатор писем на базе произвольного `AIProvider`. Собирает промпт
/// через `ClassifyV1`, парсит JSON-ответ, замеряет время и возвращает
/// `ClassificationResult` для записи в Storage + ClassificationLog.
public actor Classifier {
    public let provider: any AIProvider
    public let model: String

    public init(provider: any AIProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    public func classify(input: ClassificationInput) async throws -> ClassificationResult {
        let started = Date()
        let prompt = ClassifyV1.build(input: input)

        var buffer = ""
        for try await chunk in provider.complete(
            system: prompt.system,
            user: prompt.user,
            streaming: false,
            maxTokens: 200
        ) {
            buffer += chunk
        }
        guard !buffer.isEmpty else { throw ClassifierError.emptyResponse }

        let parsed = try parseJSON(buffer)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)

        let importance: Importance
        switch parsed.importance {
        case "important": importance = .important
        case "unimportant": importance = .unimportant
        default: importance = .unknown
        }

        let category = parsed.category.flatMap { MessageCategory(rawValue: $0) }
        let tone = parsed.tone.flatMap { MessageTone(rawValue: $0) }
        // Нормализуем язык до нижнего регистра и первых 2 символов ISO 639-1
        let language = parsed.language.map { String($0.lowercased().prefix(2)) }

        return ClassificationResult(
            importance: importance,
            confidence: parsed.confidence,
            matchedRule: nil,
            reasoning: parsed.reasoning,
            tokensIn: Self.estimateTokens(prompt.system) + Self.estimateTokens(prompt.user),
            tokensOut: Self.estimateTokens(buffer),
            durationMs: durationMs,
            category: category,
            language: language,
            tone: tone
        )
    }

    // MARK: - Private

    private struct ParsedJSON: Decodable {
        let importance: String
        let confidence: Double
        let reasoning: String
        let category: String?
        let language: String?
        let tone: String?
    }

    private func parseJSON(_ text: String) throws -> ParsedJSON {
        let json = Self.extractJSONObject(text)
        guard let data = json.data(using: .utf8) else {
            throw ClassifierError.malformedJSON(json)
        }
        do {
            return try JSONDecoder().decode(ParsedJSON.self, from: data)
        } catch {
            throw ClassifierError.malformedJSON(json)
        }
    }

    static func extractJSONObject(_ text: String) -> String {
        // Модель может обернуть JSON в ```json ... ``` или добавить текст вокруг.
        // Находим первую `{` и соответствующую ей закрывающую `}`,
        // при этом игнорируем `{`/`}` внутри JSON-строковых литералов.
        guard let start = text.firstIndex(of: "{") else { return text }
        var depth = 0
        var end: String.Index?
        var inString = false
        var escaped = false
        for idx in text.indices[start...] {
            let ch = text[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString = !inString
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { end = idx; break }
                }
            }
        }
        guard let end else { return text }
        return String(text[start...end])
    }

    static func estimateTokens(_ text: String) -> Int {
        // Грубая оценка ~4 символа на токен (для en/ru — в среднем близко).
        return max(1, text.count / 4)
    }
}
