import Foundation

/// Абстракция AI-экстрактора действий из письма. Реализуется в `AI/ActionExtractor`.
public protocol AIActionExtractor: Actor {
    /// Извлекает действия (дедлайны, задачи, встречи, ссылки, вопросы) из тела письма.
    /// - Parameter body: Plain text тело письма (только в памяти, не сохраняется).
    func extract(body: String) async throws -> [ActionItem]
}
