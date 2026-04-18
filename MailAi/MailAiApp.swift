import SwiftUI
import AppShell
import Core
import MockData

@main
struct MailAiApp: App {
    @StateObject private var registry: AccountRegistry = {
        // На фазе A используем mock-режим: один готовый аккаунт из
        // MockAccountDataProvider. В режиме .live аккаунты будут добавляться
        // через OnboardingScene (фаза A1).
        let mock = MockAccountDataProvider()
        return AccountRegistry(accounts: [mock.account], mode: .mock)
    }()

    var body: some Scene {
        // Стартовое окно — welcome / picker.
        WindowGroup("MailAi", id: "welcome") {
            WelcomeOrPickerScene(registry: registry)
        }
        .commands {
            NewAccountWindowCommands()
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if registry.accounts.isEmpty {
            WelcomeScene(
                onAddAccount: { /* TODO: фаза A1 — онбординг */ },
                onContinueWithMock: {}
            )
        } else {
            AccountPickerScene(
                registry: registry,
                onOpen: { id in openWindow(id: "account", value: id) }
            )
        }
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
