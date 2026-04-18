import Foundation

/// Вход классификатора: ровно тот набор данных, который уходит в OpenRouter.
/// Тело письма представлено строго **150 символов** plain text (из
/// `SnippetExtractor`), без HTML, без quoted-reply, без подписи.
public struct ClassificationInput: Sendable, Equatable {
    public let from: String
    public let to: [String]
    public let subject: String
    public let date: Date
    public let listUnsubscribe: Bool
    public let contentType: String
    public let bodySnippet: String
    public let activeRules: [Rule]

    /// Размер snippet'а, отправляемого в AI. Строгий инвариант.
    public static let snippetLength = 150

    public init(
        from: String,
        to: [String],
        subject: String,
        date: Date,
        listUnsubscribe: Bool,
        contentType: String,
        bodySnippet: String,
        activeRules: [Rule]
    ) {
        precondition(
            bodySnippet.count == Self.snippetLength || bodySnippet.isEmpty,
            "bodySnippet must be exactly \(Self.snippetLength) chars or empty, got \(bodySnippet.count)"
        )
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.listUnsubscribe = listUnsubscribe
        self.contentType = contentType
        self.bodySnippet = bodySnippet
        self.activeRules = activeRules
    }
}
