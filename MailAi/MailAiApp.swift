import SwiftUI
import AppShell
import Core
import MockData
import Secrets

@main
struct MailAiApp: App {
    @StateObject private var registry: AccountRegistry = {
        // C3: режим выбирается переменной окружения MOCK_DATA. По умолчанию —
        // .live (LiveAccountDataProvider); в live-режиме реестр стартует
        // пустым — аккаунты добавит онбординг (C4). В .mock подкладываем
        // демо-аккаунт из MockAccountDataProvider для dev-прогонов.
        let config = AppShellConfig.fromEnvironment()
        switch config.mode {
        case .mock:
            let mock = MockAccountDataProvider()
            return AccountRegistry(accounts: [mock.account], mode: .mock)
        case .live:
            return AccountRegistry(accounts: [], mode: .live)
        }
    }()

    // C4: секреты — только в Keychain в live, in-memory в mock/dev.
    private let secretsStore: any SecretsStore = {
        let config = AppShellConfig.fromEnvironment()
        switch config.mode {
        case .mock: return InMemorySecretsStore()
        case .live: return KeychainService(servicePrefix: "app.mailai")
        }
    }()

    var body: some Scene {
        // Стартовое окно — welcome / picker.
        WindowGroup("MailAi", id: "welcome") {
            WelcomeOrPickerScene(registry: registry, secretsStore: secretsStore)
        }
        .commands {
            NewAccountWindowCommands()
        }

        // C4: онбординг — отдельное окно, показывается по нажатию «Добавить аккаунт».
        WindowGroup("Новый аккаунт", id: "onboarding") {
            OnboardingWindow(registry: registry, secretsStore: secretsStore)
        }

        // AI-pack v1 scaffolding: окно настроек с placeholder-секцией.
        Settings {
            SettingsScene()
        }

        // Окно-под-аккаунт. SwiftUI автоматически дедуплицирует окна по
        // значению `Account.ID`: повторный `openWindow(value:)` для того же
        // id сфокусирует уже открытое окно вместо создания нового.
        WindowGroup(id: "account", for: Account.ID.self) { $accountID in
            if let id = accountID, let session = registry.session(for: id) {
                AccountWindowScene(session: session)
            } else {
                ContentUnavailableView(
                    "Аккаунт не найден",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Закройте окно и выберите аккаунт заново.")
                )
            }
        }
    }
}

/// Экран первого окна: welcome, если аккаунтов нет, иначе — picker.
private struct WelcomeOrPickerScene: View {
    @ObservedObject var registry: AccountRegistry
    let secretsStore: any SecretsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if registry.accounts.isEmpty {
            WelcomeScene(
                onAddAccount: { openWindow(id: "onboarding") },
                onContinueWithMock: {}
            )
        } else {
            AccountPickerScene(
                registry: registry,
                onOpen: { id in openWindow(id: "account", value: id) },
                onAddAccount: { openWindow(id: "onboarding") }
            )
        }
    }
}

/// Обёртка окна онбординга: создаёт свежий `OnboardingViewModel` при
/// каждом открытии и закрывает окно после успеха/отмены.
private struct OnboardingWindow: View {
    @ObservedObject var registry: AccountRegistry
    let secretsStore: any SecretsStore
    @StateObject private var model: OnboardingViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    init(registry: AccountRegistry, secretsStore: any SecretsStore) {
        self.registry = registry
        self.secretsStore = secretsStore
        _model = StateObject(wrappedValue: OnboardingViewModel(
            secretsStore: secretsStore,
            registry: registry
        ))
    }

    var body: some View {
        OnboardingScene(
            model: model,
            onCancel: { dismissWindow(id: "onboarding") },
            onCompleted: { account in
                dismissWindow(id: "onboarding")
                openWindow(id: "account", value: account.id)
            }
        )
    }
}

/// Команды для «File → New Account Window…». Отдельная `Commands`-структура
/// позволяет получить `openWindow` из Environment, чего нельзя сделать
/// напрямую в `Scene.commands`.
private struct NewAccountWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Account Window…") {
                openWindow(id: "welcome")
            }
            .keyboardShortcut("n", modifiers: [.command])
        }
    }
}
