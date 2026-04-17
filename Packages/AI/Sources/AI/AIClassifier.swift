import Foundation
import Core

/// Абстракция AI-классификатора (важное / неважное / суммаризация).
/// На MVP — только протокол и no-op реализация, реальный OpenRouter-клиент
/// появится в AI-pack (см. docs/AI.md).
public protocol AIClassifier: Sendable {
    func importance(for message: Message) async throws -> Importance
    func summary(for messages: [Message]) async throws -> String
}

public struct NoOpAIClassifier: AIClassifier {
    public init() {}
    public func importance(for message: Message) async throws -> Importance { .unknown }
    public func summary(for messages: [Message]) async throws -> String { "" }
}
