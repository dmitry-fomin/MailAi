import Foundation
import Core
import Storage
import AI
import GRDB

/// Smoke-тест RuleEngine: CRUD + subscription observeRules().
/// Использует in-memory SQLite (без файловой системы).
@main
enum RuleEngineSmoke {
    static func main() async throws {
        let (pool, cleanup) = try makePool()
        defer { cleanup() }

        let repo = RulesRepository(pool: pool)
        let engine = RuleEngine(repository: repo)

        try await testCRUD(engine: engine)
        try await testObserveRules(engine: engine)
        try await testRuleByID(engine: engine)

        print("✅ RuleEngineSmoke: все проверки пройдены")
    }

    // MARK: - Helpers

    /// Создаёт temp-файл SQLite с полной миграцией.
    /// Возвращает pool и closure для удаления temp-файла.
    private static func makePool() throws -> (DatabasePool, () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rule_engine_smoke_\(UUID().uuidString).sqlite")
        let store = try GRDBMetadataStore(url: url)
        return (store.pool, { try? FileManager.default.removeItem(at: url) })
    }

    // MARK: - CRUD

    private static func testCRUD(engine: RuleEngine) async throws {
        // 1. Создаём правило
        let rule = Rule(
            text: "Письма от boss@example.com — важные",
            intent: .markImportant,
            source: .manual
        )
        try await engine.save(rule)

        // 2. Проверяем, что оно появилось в allRules
        let all = try await engine.allRules()
        precondition(all.count == 1, "Expected 1 rule, got \(all.count)")
        precondition(all[0].text == rule.text, "Text mismatch")
        precondition(all[0].intent == .markImportant, "Intent mismatch")
        precondition(all[0].enabled == true, "Should be enabled by default")

        // 3. Проверяем activeRules (включённые)
        let active = try await engine.activeRules()
        precondition(active.count == 1, "Expected 1 active rule, got \(active.count)")

        // 4. Отключаем правило
        try await engine.setEnabled(id: rule.id, enabled: false)
        let activeAfterDisable = try await engine.activeRules()
        precondition(activeAfterDisable.isEmpty, "Expected 0 active rules after disable, got \(activeAfterDisable.count)")

        let allAfterDisable = try await engine.allRules()
        precondition(allAfterDisable.count == 1, "Rule should still exist after disable")
        precondition(allAfterDisable[0].enabled == false, "Should be disabled now")

        // 5. Включаем обратно
        try await engine.setEnabled(id: rule.id, enabled: true)
        let activeAfterEnable = try await engine.activeRules()
        precondition(activeAfterEnable.count == 1, "Expected 1 active rule after re-enable")

        // 6. Обновляем текст (upsert)
        let updated = Rule(
            id: rule.id,
            text: "Все от boss@corp.com — важные!",
            intent: .markImportant,
            enabled: true,
            createdAt: rule.createdAt,
            source: .manual
        )
        try await engine.save(updated)

        let allAfterUpdate = try await engine.allRules()
        precondition(allAfterUpdate.count == 1, "Upsert should update, not duplicate")
        precondition(allAfterUpdate[0].text == "Все от boss@corp.com — важные!", "Text should be updated")

        // 7. Удаляем
        try await engine.delete(id: rule.id)
        let allAfterDelete = try await engine.allRules()
        precondition(allAfterDelete.isEmpty, "Expected 0 rules after delete")

        let activeAfterDelete = try await engine.activeRules()
        precondition(activeAfterDelete.isEmpty, "Expected 0 active rules after delete")

        print("  ✅ CRUD — OK")
    }

    // MARK: - observeRules

    private static func testObserveRules(engine: RuleEngine) async throws {
        let stream = await engine.observeRules()
        var iterator = stream.makeAsyncIterator()

        // Создаём правило — должен прийти снапшот с 1 правилом
        let rule1 = Rule(
            text: "Рассылки от spam.com — неважные",
            intent: .markUnimportant,
            source: .manual
        )
        try await engine.save(rule1)

        let snapshot1 = await iterator.next()
        precondition(snapshot1?.count == 1, "Expected 1 rule in subscription snapshot, got \(snapshot1?.count ?? -1)")
        precondition(snapshot1?[0].text == rule1.text, "Subscription text mismatch")

        // Добавляем второе правило
        let rule2 = Rule(
            text: "Всё от ceo@corp.com — важное",
            intent: .markImportant,
            source: .dragConfirm
        )
        try await engine.save(rule2)

        let snapshot2 = await iterator.next()
        precondition(snapshot2?.count == 2, "Expected 2 rules in subscription snapshot, got \(snapshot2?.count ?? -1)")

        // Отключаем первое — должен прийти снапшот с 1 активным
        try await engine.setEnabled(id: rule1.id, enabled: false)

        let snapshot3 = await iterator.next()
        precondition(snapshot3?.count == 1, "Expected 1 active rule after disable, got \(snapshot3?.count ?? -1)")
        precondition(snapshot3?[0].id == rule2.id, "Only rule2 should be active")

        // Удаляем оставшееся — пустой снапшот
        try await engine.delete(id: rule2.id)

        let snapshot4 = await iterator.next()
        precondition(snapshot4?.isEmpty == true, "Expected empty snapshot after deleting all rules")

        // Очистка
        try await engine.delete(id: rule1.id)

        print("  ✅ observeRules — OK")
    }

    // MARK: - rule(id:)

    private static func testRuleByID(engine: RuleEngine) async throws {
        // По несуществующему ID — nil
        let notFound = try await engine.rule(id: UUID())
        precondition(notFound == nil, "Expected nil for non-existent rule ID")

        // Создаём и находим по ID
        let rule = Rule(
            text: "Новости от news@corp.com — неважные",
            intent: .markUnimportant,
            source: .import
        )
        try await engine.save(rule)

        let found = try await engine.rule(id: rule.id)
        precondition(found != nil, "Expected to find rule by ID")
        precondition(found?.text == rule.text, "Found rule text mismatch")
        precondition(found?.intent == .markUnimportant, "Found rule intent mismatch")
        precondition(found?.source == .import, "Found rule source mismatch")

        // Удаляем — снова nil
        try await engine.delete(id: rule.id)
        let afterDelete = try await engine.rule(id: rule.id)
        precondition(afterDelete == nil, "Expected nil after deletion")

        print("  ✅ rule(id:) — OK")
    }
}
