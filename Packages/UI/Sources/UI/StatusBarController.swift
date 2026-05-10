import AppKit
import SwiftUI
import Core

// MARK: - StatusBarController

/// Контроллер иконки в menu bar и бейджа Dock.
///
/// Обновляет два места:
/// 1. **Dock** — `NSApp.dockTile.badgeLabel` при `unreadCount > 0`;
///    при нуле убирает бейдж (nil).
/// 2. **Menu Bar** — `NSStatusItem` с custom-иконкой `StatusBarBadgeLabel`.
///
/// Жизненный цикл: создаётся при старте приложения, живёт до его завершения.
/// Вызовы `update(accounts:)` должны приходить с `@MainActor`.
///
/// Пример интеграции (в `App.body`):
/// ```swift
/// .onAppear {
///     StatusBarController.shared.install()
/// }
/// .onChange(of: totalUnread) { _, count in
///     StatusBarController.shared.update(totalUnread: count, accounts: accounts)
/// }
/// ```
@MainActor
public final class StatusBarController {

    public static let shared = StatusBarController()

    // MARK: - Private state

    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StatusBarBadgeLabel>?
    private var popover: NSPopover?

    /// Актуальный список аккаунтов для контента popover.
    private var accounts: [StatusBarAccountItem] = []
    private var onOpenAccount: ((Account.ID) -> Void)?
    private var onCompose: (() -> Void)?

    private init() {}

    // MARK: - Public API

    /// Устанавливает `NSStatusItem` в menu bar. Вызвать один раз при старте.
    ///
    /// - Parameters:
    ///   - onOpenAccount: Callback при выборе аккаунта в меню.
    ///   - onCompose: Callback при нажатии «Написать».
    public func install(
        onOpenAccount: @escaping (Account.ID) -> Void = { _ in },
        onCompose: @escaping () -> Void = {}
    ) {
        self.onOpenAccount = onOpenAccount
        self.onCompose = onCompose

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        // Используем NSHostingView для рендера SwiftUI-иконки в NSStatusItem.
        let badgeView = StatusBarBadgeLabel(unreadCount: 0)
        let hosting = NSHostingView(rootView: badgeView)
        hosting.frame = NSRect(x: 0, y: 0, width: 28, height: 22)
        item.button?.addSubview(hosting)
        item.button?.frame = hosting.frame
        self.hostingView = hosting

        // Клик по иконке открывает popover.
        item.button?.action = #selector(togglePopover(_:))
        item.button?.target = self
    }

    /// Обновляет бейдж Dock и иконку menu bar.
    ///
    /// - Parameters:
    ///   - totalUnread: Суммарное количество непрочитанных по всем аккаунтам.
    ///   - accounts: Список аккаунтов для отображения в popover меню.
    public func update(totalUnread: Int, accounts: [StatusBarAccountItem]) {
        self.accounts = accounts

        // --- Dock badge ---
        if totalUnread > 0 {
            let label = totalUnread > 99 ? "99+" : "\(totalUnread)"
            NSApp.dockTile.badgeLabel = label
        } else {
            NSApp.dockTile.badgeLabel = nil
        }

        // --- Menu bar icon ---
        let newBadge = StatusBarBadgeLabel(unreadCount: totalUnread)
        hostingView?.rootView = newBadge
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }

        if let existing = popover, existing.isShown {
            existing.performClose(sender)
            return
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 240, height: 200)

        let onOpen = onOpenAccount
        let onComp = onCompose
        let accs = accounts

        let content = StatusBarMenuContent(
            accounts: accs,
            onOpenAccount: { id in
                pop.performClose(nil)
                onOpen?(id)
            },
            onCompose: {
                pop.performClose(nil)
                onComp?()
            }
        )
        pop.contentViewController = NSHostingController(rootView: content)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = pop
    }
}
