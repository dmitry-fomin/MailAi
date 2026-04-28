import Foundation
import Core

public protocol SidebarProvider: Sendable {
    func sections(
        for account: Account,
        mailboxes: [Mailbox],
        messages: [Message]
    ) async -> [SidebarSection]
}

public struct MockSidebarProvider: SidebarProvider {
    public init() {}

    public func sections(
        for account: Account,
        mailboxes: [Mailbox],
        messages: [Message]
    ) async -> [SidebarSection] {
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

        // AI-5: «Отфильтрованные» — живые счётчики на основе
        // `message.importance`. Считаем письма из текущего списка
        // (visible scope = выбранная папка). Когда AI-pack отключён, поле
        // `importance` остаётся `.unknown` и счётчики будут нулевыми.
        let importantCount = messages.reduce(into: 0) { acc, m in
            if m.importance == .important { acc += 1 }
        }
        let unimportantCount = messages.reduce(into: 0) { acc, m in
            if m.importance == .unimportant { acc += 1 }
        }
        let filtered = SidebarSection(
            id: .filtered,
            title: "Отфильтрованные",
            items: [
                SidebarItem(
                    id: .init("filtered-important"),
                    title: "Важное",
                    systemImage: "exclamationmark.circle",
                    unreadCount: importantCount,
                    kind: .smartImportant
                ),
                SidebarItem(
                    id: .init("filtered-unimportant"),
                    title: "Неважно",
                    systemImage: "archivebox",
                    unreadCount: unimportantCount,
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

        // Специальные системные роли — идут первыми в секции аккаунта.
        let specialRoles: [Mailbox.Role] = [.inbox, .sent, .drafts, .trash, .spam]

        // Сортируем специальные папки по порядку из specialRoles, затем кастомные.
        let sortedMailboxes = mailboxes.sorted { lhs, rhs in
            let lhsIdx = specialRoles.firstIndex(of: lhs.role)
            let rhsIdx = specialRoles.firstIndex(of: rhs.role)
            switch (lhsIdx, rhsIdx) {
            case (.some(let a), .some(let b)): return a < b
            case (.some, .none): return true  // специальные выше кастомных
            case (.none, .some): return false
            case (.none, .none): return lhs.name.localizedCompare(rhs.name) == .orderedAscending
            }
        }

        func makeItem(for mailbox: Mailbox) -> SidebarItem {
            SidebarItem(
                id: .init("mailbox-\(mailbox.id.rawValue)"),
                title: mailbox.name,
                systemImage: SidebarIcon.name(for: mailbox.role),
                unreadCount: mailbox.unreadCount,
                kind: .mailbox(mailbox.id, role: mailbox.role)
            )
        }

        // Специальные папки → секция аккаунта.
        let specialItems = sortedMailboxes
            .filter { specialRoles.contains($0.role) }
            .map { makeItem(for: $0) }

        // Кастомные/прочие → плоский список дочерних элементов (рекурсивно).
        let otherMailboxes = sortedMailboxes
            .filter { !specialRoles.contains($0.role) }

        var otherItems: [SidebarItem] = []
        for mailbox in otherMailboxes {
            otherItems.append(makeItem(for: mailbox))
            // Первый уровень дочерних папок (иерархия IMAP).
            for child in mailbox.children {
                otherItems.append(SidebarItem(
                    id: .init("mailbox-\(child.id.rawValue)"),
                    title: "  \(child.name)", // отступ для визуальной вложенности
                    systemImage: SidebarIcon.name(for: child.role),
                    unreadCount: child.unreadCount,
                    kind: .mailbox(child.id, role: child.role)
                ))
            }
        }

        let accountSection = SidebarSection(
            id: .account,
            title: account.email,
            items: specialItems
        )

        // Если есть обычные папки — добавляем отдельную секцию «Папки».
        var sections: [SidebarSection] = [favorites, filtered, smart, accountSection]
        if !otherItems.isEmpty {
            let foldersSection = SidebarSection(
                id: .onMyMac,
                title: "Папки",
                items: otherItems
            )
            sections.append(foldersSection)
        }

        return sections
    }
}
