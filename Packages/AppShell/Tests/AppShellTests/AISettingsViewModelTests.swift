import XCTest
import Core
import Secrets
import Storage
import AI
@testable import AppShell

@MainActor
final class AISettingsViewModelTests: XCTestCase {

    private func makeStore() throws -> GRDBMetadataStore {
        let url = URL(fileURLWithPath: "/tmp/mailai-aisettings-\(UUID().uuidString).sqlite")
        return try GRDBMetadataStore(url: url)
    }

    func testLoad_initiallyEmpty() async throws {
        let secrets = InMemorySecretsStore()
        let store = try makeStore()
        let engine = RuleEngine(repository: RulesRepository(pool: store.pool))
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AISettingsStore(defaults: defaults)

        let vm = AISettingsViewModel(
            accountID: .init("acct-1"),
            accountEmail: "user@example.com",
            secrets: secrets,
            settings: settings,
            ruleEngine: engine
        )

        await vm.load()

        XCTAssertFalse(vm.aiPackEnabled)
        XCTAssertEqual(vm.modelID, OpenRouterModelCatalog.defaultModelID)
        XCTAssertEqual(vm.apiKey, "")
        XCTAssertTrue(vm.rules.isEmpty)
    }

    func testSaveAndReadAPIKey() async throws {
        let secrets = InMemorySecretsStore()
        let store = try makeStore()
        let engine = RuleEngine(repository: RulesRepository(pool: store.pool))
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AISettingsStore(defaults: defaults)
        let accountID = Account.ID("acct-2")

        let vm = AISettingsViewModel(
            accountID: accountID,
            accountEmail: "user@example.com",
            secrets: secrets,
            settings: settings,
            ruleEngine: engine
        )
        vm.apiKey = "sk-or-test-12345"
        await vm.saveAPIKey()

        let stored = try await secrets.openRouterKey(forAccount: accountID)
        XCTAssertEqual(stored, "sk-or-test-12345")

        await vm.clearAPIKey()
        let cleared = try await secrets.openRouterKey(forAccount: accountID)
        XCTAssertNil(cleared)
    }

    func testToggleEnabledAndModel() async throws {
        let secrets = InMemorySecretsStore()
        let store = try makeStore()
        let engine = RuleEngine(repository: RulesRepository(pool: store.pool))
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AISettingsStore(defaults: defaults)
        let accountID = Account.ID("acct-3")

        let vm = AISettingsViewModel(
            accountID: accountID,
            accountEmail: "user@example.com",
            secrets: secrets,
            settings: settings,
            ruleEngine: engine
        )

        await vm.setAIPackEnabled(true)
        await vm.setModelID("anthropic/claude-3.5-haiku")

        let enabled = await settings.isEnabled(forAccount: accountID)
        XCTAssertTrue(enabled)
        let modelID = await settings.modelID(forAccount: accountID)
        XCTAssertEqual(modelID, "anthropic/claude-3.5-haiku")
    }

    func testRulesCRUD() async throws {
        let secrets = InMemorySecretsStore()
        let store = try makeStore()
        let engine = RuleEngine(repository: RulesRepository(pool: store.pool))
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AISettingsStore(defaults: defaults)

        let vm = AISettingsViewModel(
            accountID: .init("acct-4"),
            accountEmail: "user@example.com",
            secrets: secrets,
            settings: settings,
            ruleEngine: engine
        )

        await vm.addRule(text: "Игнорировать рассылки", intent: .markUnimportant)
        await vm.reloadRules()
        XCTAssertEqual(vm.rules.count, 1)
        XCTAssertEqual(vm.rules.first?.text, "Игнорировать рассылки")
        XCTAssertEqual(vm.rules.first?.intent, .markUnimportant)
        XCTAssertTrue(vm.rules.first?.enabled ?? false)

        let rule = vm.rules[0]
        await vm.setRuleEnabled(rule, enabled: false)
        XCTAssertEqual(vm.rules.first?.enabled, false)

        await vm.deleteRule(vm.rules[0])
        XCTAssertTrue(vm.rules.isEmpty)
    }

    func testCatalogContainsDefault() {
        XCTAssertNotNil(OpenRouterModelCatalog.model(for: OpenRouterModelCatalog.defaultModelID))
        XCTAssertGreaterThanOrEqual(OpenRouterModelCatalog.all.count, 3)
    }
}
