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
}

/// Фабрика провайдера данных. UI-слой обязан потреблять `any AccountDataProvider`,
/// не зная деталей реализации.
public enum AccountDataProviderFactory {
    public static func make(for account: Account, mode: AppShellMode) -> any AccountDataProvider {
        switch mode {
        case .mock: return MockAccountDataProvider()
        case .live: return LiveAccountDataProvider(account: account)
        }
    }
}
