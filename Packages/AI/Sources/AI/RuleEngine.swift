import Foundation
import Core
import Storage

/// Обёртка над `RulesRepository` с кешем активных правил. Кеш
/// инвалидируется на любое изменение. Используется `Classifier`'ом для
/// подстановки правил в system-prompt.
///
/// Подписка `observeRules()` позволяет `ClassificationCoordinator`
/// реактивно обновлять промпт при изменении правил.
public actor RuleEngine {
    private let repository: RulesRepository
    private var cachedActive: [Rule]?

    /// Continuation-ы для `observeRules()`. На каждое изменение
    /// отправляем актуальный снапшот активных правил.
    private var continuations: [UUID: AsyncStream<[Rule]>.Continuation] = [:]

    public init(repository: RulesRepository) {
        self.repository = repository
    }

    public func save(_ rule: Rule) async throws {
        try await repository.upsert(rule)
        cachedActive = nil
        await notifySubscribers()
    }

    public func delete(id: UUID) async throws {
        try await repository.delete(id: id)
        cachedActive = nil
        await notifySubscribers()
    }

    public func setEnabled(id: UUID, enabled: Bool) async throws {
        try await repository.setEnabled(id: id, enabled: enabled)
        cachedActive = nil
        await notifySubscribers()
    }

    /// Возвращает одно правило по ID или `nil`, если не найдено.
    public func rule(id: UUID) async throws -> Rule? {
        try await repository.all().first(where: { $0.id == id })
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

    // MARK: - Subscription

    /// Возвращает `AsyncStream`, который при каждом изменении правил
    /// отправляет текущий снапшот активных правил.
    ///
    /// Стрим завершается (finish) только при деинициализации `RuleEngine`
    /// или при явном вызове `finish()` на returned stream consumer side.
    public func observeRules() -> AsyncStream<[Rule]> {
        let id = UUID()
        return AsyncStream { continuation in
            // onTermination вызывается из произвольного контекста —
            // используем Task, чтобы переключиться в изоляцию актора.
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id: id) }
            }
            // Task наследует изоляцию актора — await не нужен.
            Task { self.storeContinuation(continuation, id: id) }
        }
    }

    /// Сохраняет continuation для последующих уведомлений.
    /// Вынесен в отдельный метод для корректной работы Sendable.
    private func storeContinuation(_ continuation: AsyncStream<[Rule]>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    /// Отписка: вызывается автоматически при завершении стрима через onTermination,
    /// либо явно потребителем для немедленного освобождения ресурсов.
    public func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Внутренний метод для onTermination-колбека.
    private func removeObserver(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: - Internal

    /// Отправляет текущий снапшот активных правил всем подписчикам.
    /// Вызывается после каждой мутации (save/delete/setEnabled).
    private func notifySubscribers() async {
        guard !continuations.isEmpty else { return }
        // Инвалидируем кеш, чтобы получить свежие данные
        cachedActive = nil
        let snapshot = (try? await activeRules()) ?? []
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
