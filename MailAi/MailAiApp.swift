import SwiftUI
import AppShell
import Core
import MockData
import Secrets
import Storage
import UI
import UserNotifications

// MARK: - App Delegate

/// Делегат приложения: настраивает `UNUserNotificationCenter.delegate`
/// для отображения баннеров в foreground.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.setupDelegate()
    }
}

@main
struct MailAiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // C4: секреты — только в Keychain в live, in-memory в mock/dev.
    private static let sharedSecrets: any SecretsStore = {
        let config = AppShellConfig.fromEnvironment()
        switch config.mode {
        case .mock: return InMemorySecretsStore()
        case .live: return KeychainService(servicePrefix: "app.mailai")
        }
    }()

    @StateObject private var registry: AccountRegistry = {
        // C3: режим выбирается переменной окружения MOCK_DATA. По умолчанию —
        // .live (LiveAccountDataProvider); в live-режиме реестр стартует
        // пустым — аккаунты добавит онбординг (C4). В .mock подкладываем
        // демо-аккаунт из MockAccountDataProvider для dev-прогонов.
        let config = AppShellConfig.fromEnvironment()
        let dbPaths = try? DatabasePathProvider.default()
        switch config.mode {
        case .mock:
            let mock = MockAccountDataProvider()
            return AccountRegistry(
                accounts: [mock.account],
                mode: .mock,
                secrets: sharedSecrets,
                dbPaths: dbPaths
            )
        case .live:
            return AccountRegistry(
                accounts: [],
                mode: .live,
                secrets: sharedSecrets,
                dbPaths: dbPaths
            )
        }
    }()

    private var secretsStore: any SecretsStore { Self.sharedSecrets }

    /// Элементы аккаунтов для меню StatusBar.
    private var statusBarAccounts: [StatusBarAccountItem] {
        registry.accounts.map { account in
            StatusBarAccountItem(
                id: account.id,
                email: account.email,
                displayName: account.displayName,
                unreadCount: registry.unreadCount(for: account.id)
            )
        }
    }

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

        // AI-6: окно настроек, секция AI-pack — ключ OpenRouter, модель, правила.
        Settings {
            SettingsScene(registry: registry, secretsStore: secretsStore)
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

        // StatusBar: иконка в строке меню со счётчиком непрочитанных.
        MenuBarExtra {
            StatusBarMenuContent(
                accounts: statusBarAccounts,
                onOpenAccount: { id in openWindow(id: "account", value: id) },
                onCompose: { openWindow(id: "welcome") }
            )
        } label: {
            StatusBarBadgeLabel(unreadCount: registry.totalUnreadCount)
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
                onContinueWithMock: {
                    let mock = MockAccountDataProvider()
                    registry.register(mock.account, provider: mock)
                    requestNotificationPermissionIfNeeded(registry: registry)
                    openWindow(id: "account", value: mock.account.id)
                }
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

/// Запрашивает разрешение на уведомления при добавлении первого аккаунта.
/// Вызывается один раз за жизненный цикл приложения.
private func requestNotificationPermissionIfNeeded(registry: AccountRegistry) {
    guard registry.accounts.count == 1 else { return }
    Task {
        _ = await NotificationManager.shared.requestPermission()
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
                requestNotificationPermissionIfNeeded(registry: registry)
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
