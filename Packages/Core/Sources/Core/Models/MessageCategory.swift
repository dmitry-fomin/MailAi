import Foundation

/// AI-категория письма. Устанавливается классификатором, хранится в Storage.
public enum MessageCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case work
    case finance
    case travel
    case social
    case legal
    case receipt
    case notification
    case personal
    case marketing
    case other
}

/// Тон письма, определяемый AI.
public enum MessageTone: String, Sendable, Hashable, Codable, CaseIterable {
    case positive
    case neutral
    case negative
    case urgent
}
