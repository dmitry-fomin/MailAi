#if canImport(XCTest)
import XCTest
@testable import AppShell
import Core

@MainActor
final class SidebarViewModelTests: XCTestCase {
    private func makeAccount() -> Account {
        Account(
            id: .init("acc-1"),
            email: "user@example.com",
            displayName: "User",
            kind: .imap,
            host: "imap.example.com",
            port: 993,
            security: .tls,
            username: "user"
        )
    }

    private func makeMailbox(
        id: String,
        name: String,
        role: Mailbox.Role,
        unread: Int = 0
    ) -> Mailbox {
        Mailbox(
            id: .init(id),
            accountID: .init("acc-1"),
            name: name,
            path: name,
            role: role,
            unreadCount: unread,
            totalCount: unread + 5,
            uidValidity: 1
        )
    }

    func testRebuildProducesFiveSections() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox, unread: 3),
            makeMailbox(id: "sent", name: "Sent", role: .sent)
        ])
        XCTAssertEqual(
            vm.sections.map(\.id),
            [.favorites, .filtered, .smartBoxes, .onMyMac, .account]
        )
        XCTAssertEqual(vm.sections.last?.title, "user@example.com")
    }

    func testAccountSectionContainsAllMailboxesWithIcons() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox, unread: 7),
            makeMailbox(id: "trash", name: "Trash", role: .trash),
            makeMailbox(id: "spam", name: "Spam", role: .spam)
        ])
        let accountSection = vm.sections.first(where: { $0.id == .account })
        XCTAssertEqual(accountSection?.items.count, 3)
        let inbox = accountSection?.items.first
        XCTAssertEqual(inbox?.systemImage, "tray.and.arrow.down")
        XCTAssertEqual(inbox?.unreadCount, 7)
        let spam = accountSection?.items.last
        XCTAssertEqual(spam?.systemImage, "exclamationmark.octagon")
    }

    func testDefaultSelectionIsInbox() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "sent", name: "Sent", role: .sent),
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox)
        ])
        let mailboxID = vm.mailboxID(for: vm.selectedItemID)
        XCTAssertEqual(mailboxID, .init("inbox"))
    }

    func testDefaultSelectionFallsBackToFirstWhenNoInbox() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "archive", name: "Archive", role: .archive),
            makeMailbox(id: "sent", name: "Sent", role: .sent)
        ])
        XCTAssertNotNil(vm.selectedItemID)
        XCTAssertEqual(vm.mailboxID(for: vm.selectedItemID), .init("archive"))
    }

    func testRebuildPreservesValidSelection() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox),
            makeMailbox(id: "sent", name: "Sent", role: .sent)
        ])
        vm.selectMailbox(.init("sent"))
        let beforeID = vm.selectedItemID
        await vm.rebuild(with: [
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox, unread: 1),
            makeMailbox(id: "sent", name: "Sent", role: .sent)
        ])
        XCTAssertEqual(vm.selectedItemID, beforeID)
    }

    func testRebuildResetsInvalidSelection() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "old", name: "Old", role: .custom)
        ])
        vm.selectMailbox(.init("old"))
        await vm.rebuild(with: [
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox)
        ])
        XCTAssertEqual(vm.mailboxID(for: vm.selectedItemID), .init("inbox"))
    }

    func testSmartUnreadAggregatesUnreadCounts() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox, unread: 4),
            makeMailbox(id: "spam", name: "Spam", role: .spam, unread: 2)
        ])
        let smart = vm.sections.first(where: { $0.id == .smartBoxes })
        let unread = smart?.items.first(where: {
            if case .smartUnread = $0.kind { return true }
            return false
        })
        XCTAssertEqual(unread?.unreadCount, 6)
    }

    func testFavoritesSectionContainsFlaggedAndDrafts() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [])
        let favorites = vm.sections.first(where: { $0.id == .favorites })
        XCTAssertEqual(favorites?.title, "Избранное")
        XCTAssertEqual(favorites?.items.count, 2)
    }

    func testOnMyMacSectionPresent() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [])
        let local = vm.sections.first(where: { $0.id == .onMyMac })
        XCTAssertEqual(local?.title, "На моём Mac")
        XCTAssertFalse(local?.items.isEmpty ?? true)
    }

    private func makeMessage(
        id: String,
        importance: Importance,
        mailboxID: String = "inbox"
    ) -> Message {
        Message(
            id: .init(id),
            accountID: .init("acc-1"),
            mailboxID: .init(mailboxID),
            uid: 0,
            messageID: nil,
            threadID: nil,
            subject: "s",
            from: nil,
            to: [],
            cc: [],
            date: Date(),
            preview: nil,
            size: 0,
            flags: [],
            importance: importance
        )
    }

    func testFilteredCountersMatchImportance() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(
            with: [makeMailbox(id: "inbox", name: "INBOX", role: .inbox)],
            messages: [
                makeMessage(id: "1", importance: .important),
                makeMessage(id: "2", importance: .important),
                makeMessage(id: "3", importance: .unimportant),
                makeMessage(id: "4", importance: .unknown)
            ]
        )
        let filtered = vm.sections.first(where: { $0.id == .filtered })
        XCTAssertNotNil(filtered)
        let important = filtered?.items.first(where: {
            if case .smartImportant = $0.kind { return true }
            return false
        })
        let unimportant = filtered?.items.first(where: {
            if case .smartUnimportant = $0.kind { return true }
            return false
        })
        XCTAssertEqual(important?.unreadCount, 2)
        XCTAssertEqual(unimportant?.unreadCount, 1)
    }

    func testFilteredCountersAreZeroWhenNoMessages() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [makeMailbox(id: "inbox", name: "INBOX", role: .inbox)])
        let filtered = vm.sections.first(where: { $0.id == .filtered })
        XCTAssertEqual(filtered?.items.allSatisfy { $0.unreadCount == 0 }, true)
    }

    func testMailboxIDForNonMailboxItemReturnsNil() async {
        let vm = SidebarViewModel(account: makeAccount())
        await vm.rebuild(with: [
            makeMailbox(id: "inbox", name: "INBOX", role: .inbox)
        ])
        let favorites = vm.sections.first(where: { $0.id == .favorites })
        let firstFavoriteID = favorites?.items.first?.id
        XCTAssertNil(vm.mailboxID(for: firstFavoriteID))
    }
}
#endif
