import SwiftUI
import AI
import AppShell
import Core
import MockData
import Secrets
import Storage
import UI
import UserNotifications

// MARK: - Compose window value

/// SMTP-5: значение, идентифицирующее compose-окно. Привязано к аккаунту,
/// но в отличие от `account` window-id допускает несколько одновременных
/// окон (черновики).
struct ComposeWindowValue: Hashable, Codable {
    let accountID: Account.ID
    let nonce: UUID

    init(accountID: Account.ID) {
        self.accountID = accountID
        self.nonce = UUID()
    }
}

// MARK: - App Delegate

/// Делегат приложения: настраивает `UNUserNotificationCenter.delegate`
/// для отображения баннеров в foreground.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.setupDelegate()
        Task {
            try? await PromptStore.shared.initializeDefaults()
        }
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
            ComposeCommands(registry: registry)
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

        // SMTP-5: окно compose. Каждое значение `ComposeWindowValue.nonce`
        // даёт отдельное окно, чтобы можно было параллельно писать несколько
        // черновиков. Тело и поля живут только в @StateObject — на диск не пишутся.
        WindowGroup("Новое письмо", id: "compose", for: ComposeWindowValue.self) { $value in
            if let value, let session = registry.session(for: value.accountID) {
                ComposeWindow(session: session, mode: registry.mode, secrets: secretsStore)
            } else {
                ContentUnavailableView(
                    "Аккаунт не выбран",
                    systemImage: "envelope",
                    description: Text("Откройте окно аккаунта и выберите ⌘N снова.")
                )
            }
        }

        // StatusBar: иконка в строке меню со счётчиком непрочитанных.
        MenuBarExtra {
            StatusBarMenu(registry: registry, statusBarAccounts: statusBarAccounts)
        } label: {
            StatusBarBadgeLabel(unreadCount: registry.totalUnreadCount)
        }
    }
}

/// Обёртка для содержимого `MenuBarExtra` — нужна, чтобы получить
/// `@Environment(\.openWindow)`: на уровне `App.body` это окружение
/// недоступно, его поставляет SwiftUI только внутри View-иерархии.
private struct StatusBarMenu: View {
    @ObservedObject var registry: AccountRegistry
    let statusBarAccounts: [StatusBarAccountItem]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        StatusBarMenuContent(
            accounts: statusBarAccounts,
            onOpenAccount: { id in openWindow(id: "account", value: id) },
            onCompose: { openWindow(id: "welcome") }
        )
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
/// Вызывается один раз за жизненный цикл приложения. `@MainActor`, так как
/// читает `registry.accounts` (AccountRegistry изолирован на MainActor).
@MainActor
private func requestNotificationPermissionIfNeeded(registry: AccountRegistry) {
    guard registry.accounts.count == 1 else { return }
    Task {
        _ = await NotificationManager.shared.requestPermission()
    }
}

/// Обёртка окна онбординга. Первый шаг — выбор типа аккаунта (IMAP / Exchange),
/// затем — соответствующая форма. Все три шага живут в одном окне.
private struct OnboardingWindow: View {
    @ObservedObject var registry: AccountRegistry
    let secretsStore: any SecretsStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    private enum Step { case picker, imap, exchange }
    @State private var step: Step = .picker

    @StateObject private var imapModel: OnboardingViewModel
    @StateObject private var exchangeModel: ExchangeOnboardingViewModel

    init(registry: AccountRegistry, secretsStore: any SecretsStore) {
        self.registry = registry
        self.secretsStore = secretsStore
        _imapModel = StateObject(wrappedValue: OnboardingViewModel(
            secretsStore: secretsStore,
            registry: registry
        ))
        _exchangeModel = StateObject(wrappedValue: ExchangeOnboardingViewModel(
            secretsStore: secretsStore,
            registry: registry
        ))
    }

    var body: some View {
        switch step {
        case .picker:
            AccountTypePickerScene(
                onSelectIMAP: { step = .imap },
                onSelectExchange: { step = .exchange },
                onCancel: { dismissWindow(id: "onboarding") }
            )
        case .imap:
            OnboardingScene(
                model: imapModel,
                onCancel: { step = .picker },
                onCompleted: { account in
                    dismissWindow(id: "onboarding")
                    requestNotificationPermissionIfNeeded(registry: registry)
                    openWindow(id: "account", value: account.id)
                }
            )
        case .exchange:
            ExchangeOnboardingScene(
                model: exchangeModel,
                onCancel: { step = .picker },
                onCompleted: { account in
                    dismissWindow(id: "onboarding")
                    requestNotificationPermissionIfNeeded(registry: registry)
                    openWindow(id: "account", value: account.id)
                }
            )
        }
    }
}

/// Команды для «File → New Account Window…». SMTP-5: ⌘N теперь открывает
/// окно нового письма (см. `ComposeCommands`), а «New Account Window»
/// перевешен на ⌘⇧N — это меньше конфликтует с системными ожиданиями
/// (mail.app: ⌘N = новое письмо).
private struct NewAccountWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Account Window…") {
                openWindow(id: "welcome")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

/// SMTP-5: команда «File → New Message» (⌘N). Открывает compose-окно для
/// первого активного аккаунта. Если аккаунтов нет — открывает welcome.
private struct ComposeCommands: Commands {
    @ObservedObject var registry: AccountRegistry
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Message") {
                if let account = registry.accounts.first {
                    openWindow(
                        id: "compose",
                        value: ComposeWindowValue(accountID: account.id)
                    )
                } else {
                    openWindow(id: "welcome")
                }
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(registry.accounts.isEmpty)
        }
    }
}

/// Обёртка-владелец `ComposeViewModel` — `@StateObject` живёт ровно столько,
/// сколько окно. Тело письма — только в памяти этой VM.
private struct ComposeWindow: View {
    @StateObject private var model: ComposeViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(session: AccountSessionModel, mode: AppShellMode, secrets: any SecretsStore) {
        let sendProvider = AccountDataProviderFactory.makeSendProvider(
            for: session.account,
            mode: mode,
            secrets: secrets
        )
        let draftSaver = AccountDataProviderFactory.makeDraftSaver(
            provider: session.provider
        )
        _model = StateObject(wrappedValue: ComposeViewModel(
            accountEmail: session.account.email,
            accountDisplayName: session.account.displayName,
            sendProvider: sendProvider,
            draftSaver: draftSaver
        ))
    }

    var body: some View {
        ComposeScene(model: model, onClose: { dismissWindow() })
    }
}
