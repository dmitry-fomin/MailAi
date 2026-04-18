import Foundation
import Core

public protocol SidebarProvider: Sendable {
    func sections(for account: Account, mailboxes: [Mailbox]) async -> [SidebarSection]
}

public struct MockSidebarProvider: SidebarProvider {
    public init() {}

    public func sections(for account: Account, mailboxes: [Mailbox]) async -> [SidebarSection] {
        let favorites = SidebarSection(
            id: .favorites,
            title: "Избранное",
            items: [
                SidebarItem(
                    id: .init("fav-flagged"),
                    title: "Флажки",
                    systemImage: "flag.fill",
                    unreadCount: 0,
                    kind: .favoriteFlagged
                ),
                SidebarItem(
                    id: .init("fav-drafts"),
                    title: "Черновики",
                    systemImage: "square.and.pencil",
                    unreadCount: 0,
                    kind: .favoriteDrafts
                )
            ]
        )

        let totalUnread = mailboxes.reduce(0) { $0 + $1.unreadCount }

        // AI-pack v1: «Отфильтрованные» — каркас для будущей AI-классификации.
        // В v1 счётчики всегда 0 и клик открывает empty-state с подсказкой
        // «включите AI-pack в настройках».
        let filtered = SidebarSection(
            id: .filtered,
            title: "Отфильтрованные",
            items: [
                SidebarItem(
                    id: .init("filtered-important"),
                    title: "Важное",
                    systemImage: "exclamationmark.circle",
                    unreadCount: 0,
                    kind: .smartImportant
                ),
                SidebarItem(
                    id: .init("filtered-unimportant"),
                    title: "Неважно",
                    systemImage: "archivebox",
                    unreadCount: 0,
                    kind: .smartUnimportant
                )
            ]
        )

        let smart = SidebarSection(
            id: .smartBoxes,
            title: "Смарт-ящики",
            items: [
                SidebarItem(
                    id: .init("smart-unread"),
                    title: "Непрочитанные",
                    systemImage: "envelope.badge",
                    unreadCount: totalUnread,
                    kind: .smartUnread
                )
            ]
        )

        let onMac = SidebarSection(
            id: .onMyMac,
            title: "На моём Mac",
            items: [
                SidebarItem(
                    id: .init("local-archive"),
                    title: "Локальный архив",
                    systemImage: "internaldrive",
                    unreadCount: 0,
                    kind: .localFolder(name: "Локальный архив")
                )
            ]
        )

        let mailboxItems = mailboxes.map { mailbox in
            SidebarItem(
                id: .init("mailbox-\(mailbox.id.rawValue)"),
                title: mailbox.name,
                systemImage: SidebarIcon.name(for: mailbox.role),
                unreadCount: mailbox.unreadCount,
                kind: .mailbox(mailbox.id, role: mailbox.role)
            )
        }
        let accountSection = SidebarSection(
            id: .account,
            title: account.email,
            items: mailboxItems
        )

        return [favorites, filtered, smart, onMac, accountSection]
    }
}
