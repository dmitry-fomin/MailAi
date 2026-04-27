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
            return LiveAccountDataProvider(
                account: account,
                store: store ?? InMemoryMetadataStore(),
                secrets: secrets
            )
        }
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
