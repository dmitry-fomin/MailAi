import Foundation
import Core

/// Per-account настройки AI-pack: глобальный флаг "включено" + выбранная
/// модель OpenRouter. Сам API-ключ живёт в Keychain (см. `SecretsStore`).
///
/// Хранится в `UserDefaults`. Ключи никогда сюда не пишутся.
public actor AISettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isEnabled(forAccount accountID: Account.ID) -> Bool {
        defaults.bool(forKey: Self.enabledKey(accountID))
    }

    public func setEnabled(_ enabled: Bool, forAccount accountID: Account.ID) {
        defaults.set(enabled, forKey: Self.enabledKey(accountID))
    }

    public func modelID(forAccount accountID: Account.ID) -> String {
        defaults.string(forKey: Self.modelKey(accountID))
            ?? OpenRouterModelCatalog.defaultModelID
    }

    public func setModelID(_ id: String, forAccount accountID: Account.ID) {
        defaults.set(id, forKey: Self.modelKey(accountID))
    }

    private static func enabledKey(_ id: Account.ID) -> String {
        "ai.pack.enabled.\(id.rawValue)"
    }

    private static func modelKey(_ id: Account.ID) -> String {
        "ai.pack.model.\(id.rawValue)"
    }
}

/// Преднастроенный каталог моделей OpenRouter, которые предлагаем в Settings.
/// Список фиксированный — пользователь выбирает из выпадающего меню.
public struct OpenRouterModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let provider: String

    public init(id: String, displayName: String, provider: String) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
    }
}

public enum OpenRouterModelCatalog {
    /// Дефолтная модель — относительно дешёвая и быстрая для классификации.
    public static let defaultModelID: String = "deepseek/deepseek-chat"

    public static let all: [OpenRouterModel] = [
        OpenRouterModel(
            id: "deepseek/deepseek-chat",
            displayName: "DeepSeek Chat",
            provider: "DeepSeek"
        ),
        OpenRouterModel(
            id: "deepseek/deepseek-r1",
            displayName: "DeepSeek R1",
            provider: "DeepSeek"
        ),
        OpenRouterModel(
            id: "anthropic/claude-3.5-haiku",
            displayName: "Claude 3.5 Haiku",
            provider: "Anthropic"
        ),
        OpenRouterModel(
            id: "anthropic/claude-3.5-sonnet",
            displayName: "Claude 3.5 Sonnet",
            provider: "Anthropic"
        ),
        OpenRouterModel(
            id: "openai/gpt-4o-mini",
            displayName: "GPT-4o mini",
            provider: "OpenAI"
        ),
        OpenRouterModel(
            id: "openai/gpt-4o",
            displayName: "GPT-4o",
            provider: "OpenAI"
        )
    ]

    public static func model(for id: String) -> OpenRouterModel? {
        all.first { $0.id == id }
    }
}
