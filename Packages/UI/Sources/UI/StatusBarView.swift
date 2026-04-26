import SwiftUI
import Core

// MARK: - Data Models

/// Данные аккаунта для отображения в меню StatusBar.
/// Лёгкая структура-проекция — не тянет за собой весь `Account`.
public struct StatusBarAccountItem: Identifiable, Sendable {
    public let id: Account.ID
    public let email: String
    public let displayName: String?
    public let unreadCount: Int

    public init(
        id: Account.ID,
        email: String,
        displayName: String?,
        unreadCount: Int
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.unreadCount = unreadCount
    }
}

// MARK: - Badge Label

/// Иконка конверта с красным бейджем непрочитанных. При count == 0
/// показывается чистый конверт без бейджа. При >99 — «99+» (экономим
/// ширину, как в docs/StatusBar.md).
public struct StatusBarBadgeLabel: View {
    private let unreadCount: Int

    public init(unreadCount: Int) {
        self.unreadCount = unreadCount
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "envelope")
            if unreadCount > 0 {
                Text(badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
                    .offset(x: 6, y: -4)
            }
        }
    }

    private var badgeText: String {
        unreadCount > 99 ? "99+" : "\(unreadCount)"
    }
}

// MARK: - Menu Content

/// Содержимое выпадающего меню StatusBar: список аккаунтов с их
/// счётчиками, «Написать» и «Настройки…».
///
/// Не создаёт `MenuBarExtra` сама — это `Scene`, она живёт в `App`.
/// Эта view — только тело меню, которое вызывающий код размещает внутри
/// `MenuBarExtra { … }`.
public struct StatusBarMenuContent: View {
    private let accounts: [StatusBarAccountItem]
    private let onOpenAccount: (Account.ID) -> Void
    private let onCompose: () -> Void

    public init(
        accounts: [StatusBarAccountItem],
        onOpenAccount: @escaping (Account.ID) -> Void,
        onCompose: @escaping () -> Void
    ) {
        self.accounts = accounts
        self.onOpenAccount = onOpenAccount
        self.onCompose = onCompose
    }

    public var body: some View {
        if accounts.isEmpty {
            Text("Нет аккаунтов")
                .foregroundStyle(.secondary)
        } else {
            ForEach(accounts) { item in
                Button {
                    onOpenAccount(item.id)
                } label: {
                    HStack {
                        Text(item.displayName ?? item.email)
                        Spacer()
                        if item.unreadCount > 0 {
                            Text("\(item.unreadCount)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        Divider()

        Button("Написать") {
            onCompose()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        SettingsLink {
            Text("Настройки…")
        }
    }
}
