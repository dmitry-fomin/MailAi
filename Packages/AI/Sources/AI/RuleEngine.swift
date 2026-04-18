import Foundation
import Core
import Storage

/// Обёртка над `RulesRepository` с кешем активных правил. Кеш
/// инвалидируется на любое изменение. Используется `Classifier`'ом для
/// подстановки правил в system-prompt.
public actor RuleEngine {
    private let repository: RulesRepository
    private var cachedActive: [Rule]?

    public init(repository: RulesRepository) {
        self.repository = repository
    }

    public func save(_ rule: Rule) async throws {
        try await repository.upsert(rule)
        cachedActive = nil
    }

    public func delete(id: UUID) async throws {
        try await repository.delete(id: id)
        cachedActive = nil
    }

    public func setEnabled(id: UUID, enabled: Bool) async throws {
        try await repository.setEnabled(id: id, enabled: enabled)
        cachedActive = nil
    }

    public func activeRules() async throws -> [Rule] {
        if let cachedActive { return cachedActive }
        let fetched = try await repository.active()
        cachedActive = fetched
        return fetched
    }

    public func allRules() async throws -> [Rule] {
        try await repository.all()
    }

    public func invalidateCache() {
        cachedActive = nil
    }
}
