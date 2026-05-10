import Foundation

/// Входной срез одного письма для суммаризатора треда.
/// Содержит только метаданные + короткий snippet тела — не полный HTML.
public struct MessageSummaryInput: Sendable, Equatable {
    public let from: String
    public let date: Date
    /// Первые 300 символов plain text тела письма.
    public let bodySnippet: String

    public static let snippetLength = 300

    public init(from: String, date: Date, bodySnippet: String) {
        self.from = from
        self.date = date
        self.bodySnippet = String(bodySnippet.prefix(Self.snippetLength))
    }
}

/// Результат суммаризации треда. Живёт только в памяти / ai_cache.
public struct ThreadSummary: Sendable, Identifiable, Equatable {
    public let id: String
    /// 2–3 предложения, описывающие суть переписки.
    public let text: String
    /// Уникальные адреса участников треда.
    public let participants: [String]
    /// Ключевые решения или факты, извлечённые из треда.
    public let keyPoints: [String]
    public let tokensIn: Int
    public let tokensOut: Int

    public init(
        id: String,
        text: String,
        participants: [String],
        keyPoints: [String],
        tokensIn: Int,
        tokensOut: Int
    ) {
        self.id = id
        self.text = text
        self.participants = participants
        self.keyPoints = keyPoints
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
    }
}
