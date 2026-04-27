import Foundation
import Combine
import Core
import Secrets
import Storage
import AI

/// View-model для секции Settings → AI-pack. Изоляция UI на главном потоке;
/// все обращения к Keychain/GRDB — через async API соответствующих actor'ов.
///
/// Никогда не логирует значение API-ключа и тексты правил.
@MainActor
public final class AISettingsViewModel: ObservableObject {
    // MARK: - Published State

    @Published public var aiPackEnabled: Bool = false
    @Published public var apiKey: String = ""
    @Published public var modelID: String = OpenRouterModelCatalog.defaultModelID
    @Published public private(set) var rules: [Rule] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var statusMessage: String?

    public let availableModels: [OpenRouterModel] = OpenRouterModelCatalog.all

    // MARK: - Dependencies

    public let accountID: Account.ID
    public let accountEmail: String
    private let secrets: any SecretsStore
    private let settings: AISettingsStore
    private let ruleEngine: RuleEngine?

    public init(
        accountID: Account.ID,
        accountEmail: String,
        secrets: any SecretsStore,
        settings: AISettingsStore,
        ruleEngine: RuleEngine?
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.secrets = secrets
        self.settings = settings
        self.ruleEngine = ruleEngine
    }

    // MARK: - Load

    public func load() async {
        isLoading = true
        defer { isLoading = false }

        aiPackEnabled = await settings.isEnabled(forAccount: accountID)
        modelID = await settings.modelID(forAccount: accountID)
        do {
            apiKey = try await secrets.openRouterKey(forAccount: accountID) ?? ""
        } catch {
            apiKey = ""
            statusMessage = "Не удалось прочитать ключ из Keychain"
        }
        await reloadRules()
    }

    // MARK: - Settings persistence

    public func setAIPackEnabled(_ enabled: Bool) async {
        aiPackEnabled = enabled
        await settings.setEnabled(enabled, forAccount: accountID)
    }

    public func setModelID(_ id: String) async {
        modelID = id
        await settings.setModelID(id, forAccount: accountID)
    }

    public func saveAPIKey() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try await secrets.deleteOpenRouterKey(forAccount: accountID)
                statusMessage = "Ключ удалён"
            } else {
                try await secrets.setOpenRouterKey(trimmed, forAccount: accountID)
                statusMessage = "Ключ сохранён"
            }
        } catch {
            statusMessage = "Ошибка сохранения ключа"
        }
    }

    public func clearAPIKey() async {
        apiKey = ""
        await saveAPIKey()
    }

    // MARK: - Rules

    public func reloadRules() async {
        guard let ruleEngine else {
            rules = []
            return
        }
        do {
            rules = try await ruleEngine.allRules()
        } catch {
            rules = []
            statusMessage = "Не удалось загрузить правила"
        }
    }

    public func setRuleEnabled(_ rule: Rule, enabled: Bool) async {
        guard let ruleEngine else { return }
        do {
            try await ruleEngine.setEnabled(id: rule.id, enabled: enabled)
            await reloadRules()
        } catch {
            statusMessage = "Не удалось изменить правило"
        }
    }

    public func addRule(text: String, intent: Rule.Intent) async {
        guard let ruleEngine else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let rule = Rule(text: trimmed, intent: intent, source: .manual)
        do {
            try await ruleEngine.save(rule)
            await reloadRules()
        } catch {
            statusMessage = "Не удалось сохранить правило"
        }
    }

    public func deleteRule(_ rule: Rule) async {
        guard let ruleEngine else { return }
        do {
            try await ruleEngine.delete(id: rule.id)
            await reloadRules()
        } catch {
            statusMessage = "Не удалось удалить правило"
        }
    }
}
