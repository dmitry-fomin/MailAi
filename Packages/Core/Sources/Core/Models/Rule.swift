import Foundation

/// Правило пользователя для AI-классификатора. Текст — на естественном языке,
/// подставляется в system-prompt. Intent определяет, в какую сторону смещать
/// решение AI.
public struct Rule: Sendable, Hashable, Identifiable, Codable {
    public enum Intent: String, Sendable, Hashable, Codable {
        case markImportant
        case markUnimportant
    }

    public enum Source: String, Sendable, Hashable, Codable {
        case manual
        case dragConfirm
        case `import`
    }

    public let id: UUID
    public var text: String
    public var intent: Intent
    public var enabled: Bool
    public let createdAt: Date
    public let source: Source

    public init(
        id: UUID = UUID(),
        text: String,
        intent: Intent,
        enabled: Bool = true,
        createdAt: Date = Date(),
        source: Source
    ) {
        self.id = id
        self.text = text
        self.intent = intent
        self.enabled = enabled
        self.createdAt = createdAt
        self.source = source
    }
}
