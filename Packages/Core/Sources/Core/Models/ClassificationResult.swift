import Foundation

/// Результат классификации: решение AI + телеметрия (для `ClassificationLog`).
/// `matchedRule` заполняется, если один из user-rules явно применился
/// (RuleEngine.v2, вне v1 AI-pack — пока `nil`).
public struct ClassificationResult: Sendable, Equatable {
    public let importance: Importance
    public let confidence: Double
    public let matchedRule: UUID?
    public let reasoning: String
    public let tokensIn: Int
    public let tokensOut: Int
    public let durationMs: Int
    /// AI-категория письма (work, finance, social и т.д.). Заполняется ClassifyV1.
    public let category: MessageCategory?
    /// Язык письма в формате ISO 639-1 (например "en", "ru"). Заполняется ClassifyV1.
    public let language: String?
    /// Тон письма (positive, neutral, negative, urgent). Заполняется ClassifyV1.
    public let tone: MessageTone?

    public init(
        importance: Importance,
        confidence: Double,
        matchedRule: UUID? = nil,
        reasoning: String,
        tokensIn: Int,
        tokensOut: Int,
        durationMs: Int,
        category: MessageCategory? = nil,
        language: String? = nil,
        tone: MessageTone? = nil
    ) {
        self.importance = importance
        self.confidence = confidence
        self.matchedRule = matchedRule
        self.reasoning = reasoning
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.durationMs = durationMs
        self.category = category
        self.language = language
        self.tone = tone
    }
}
