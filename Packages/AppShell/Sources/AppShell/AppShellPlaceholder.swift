import Foundation
import Core
import MockData
import Storage
import Secrets
import MailTransport
import AI

/// Composition root приложения: сборка DI-графа, выбор провайдера
/// (MockAccountDataProvider / LiveAccountDataProvider), многооконность.
/// Реальные Scenes/ViewModels появятся в фазе A — см. IMPLEMENTATION_PLAN.md.
public enum AppShellMode: String, Sendable {
    case mock
    case live
}

public struct AppShellConfig: Sendable {
    public let mode: AppShellMode
    public init(mode: AppShellMode) { self.mode = mode }

    /// Читает конфигурацию из окружения. `MOCK_DATA=1` включает мок-провайдер;
    /// без флага — live-режим (реальный IMAP через `LiveAccountDataProvider`).
    /// На фазе C3 это единственный способ переключения; онбординг появится в C4.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> AppShellConfig {
        let mockFlag = env["MOCK_DATA"]?.lowercased()
        let isMock = mockFlag == "1" || mockFlag == "true" || mockFlag == "yes"
        return AppShellConfig(mode: isMock ? .mock : .live)
    }
}

/// Фабрика провайдера данных. UI-слой обязан потреблять `any AccountDataProvider`,
/// не зная деталей реализации.
public enum AccountDataProviderFactory {
    public static func make(
        for account: Account,
        mode: AppShellMode,
        secrets: (any SecretsStore)? = nil,
        store: (any MetadataStore)? = nil
    ) -> any AccountDataProvider {
        switch mode {
        case .mock: return MockAccountDataProvider()
        case .live:
            if account.kind == .exchange {
                return makeExchange(account: account, secrets: secrets)
            }
            return LiveAccountDataProvider(
                account: account,
                store: store ?? InMemoryMetadataStore(),
                secrets: secrets
            )
        }
    }

    private static func makeExchange(account: Account, secrets: (any SecretsStore)?) -> any AccountDataProvider {
        // БАГ-3: EWS URL сохраняется при онбординге в отдельный слот Keychain
        // (accountID + ":ewsURL"). Здесь строим fallback URL синхронно из данных
        // аккаунта — он будет заменён правильным через makeExchangeAsync при старте.
        // Вызвать secrets.password синхронно нельзя (async API), поэтому
        // используем AccountRegistry.restoreExchangeProvider(for:) при запуске.
        let scheme = account.security == .none ? "http" : "https"
        let ewsURL = URL(string: "\(scheme)://\(account.host)/EWS/Exchange.asmx")!
        let client = EWSClient(ewsURL: ewsURL, username: account.username, password: "")
        return EWSAccountDataProvider(account: account, client: client)
    }

    /// БАГ-3: Async-вариант для восстановления Exchange-провайдера при старте.
    /// Читает сохранённый EWS URL и пароль из Keychain.
    /// Вызывается из `AccountRegistry.restoreExchangeProvider(for:)`.
    public static func makeExchangeAsync(
        account: Account,
        secrets: any SecretsStore
    ) async throws -> any AccountDataProvider {
        let ewsURLKey = Account.ID(account.id.rawValue + ":ewsURL")
        let scheme = account.security == .none ? "http" : "https"
        let fallbackURLString = "\(scheme)://\(account.host)/EWS/Exchange.asmx"
        let storedURLString = try await secrets.password(forAccount: ewsURLKey)
        let ewsURL = storedURLString.flatMap { URL(string: $0) }
            ?? URL(string: fallbackURLString)!
        return try await EWSAccountDataProvider.make(account: account, ewsURL: ewsURL, secrets: secrets)
    }

    /// Собирает `SendProvider` для аккаунта. Возвращает `nil`, если режим
    /// `.mock` или у аккаунта не настроены SMTP-поля (`smtpHost/smtpPort/
    /// smtpSecurity`) — в этом случае UI скрывает кнопку «Отправить».
    public static func makeSendProvider(
        for account: Account,
        mode: AppShellMode,
        secrets: (any SecretsStore)? = nil
    ) -> (any SendProvider)? {
        switch mode {
        case .mock:
            return nil
        case .live:
            guard let secrets else { return nil }
            guard LiveSendProvider.resolveEndpoint(for: account) != nil else { return nil }
            return try? LiveSendProvider(account: account, secrets: secrets)
        }
    }

    /// SMTP-5: возвращает замыкание для сохранения черновика через
    /// `LiveAccountDataProvider.saveDraft(envelope:body:)`. Возвращает `nil`
    /// для mock-режима или если provider не умеет writes.
    public static func makeDraftSaver(
        provider: any AccountDataProvider
    ) -> ComposeViewModel.DraftSaver? {
        guard let live = provider as? LiveAccountDataProvider else { return nil }
        return { envelope, body in
            try await live.saveDraft(envelope: envelope, body: body)
        }
    }
}
