import Foundation
import Core

@MainActor
public final class SidebarViewModel: ObservableObject {
    @Published public private(set) var sections: [SidebarSection] = []
    @Published public var selectedItemID: SidebarItem.ID?

    public let account: Account
    private let provider: any SidebarProvider

    public init(
        account: Account,
        provider: any SidebarProvider = MockSidebarProvider()
    ) {
        self.account = account
        self.provider = provider
    }

    public func rebuild(with mailboxes: [Mailbox], messages: [Message] = []) async {
        let next = await provider.sections(
            for: account,
            mailboxes: mailboxes,
            messages: messages
        )
        sections = next
        if selectedItemID == nil {
            selectedItemID = defaultSelection(in: next)
        } else if !contains(itemID: selectedItemID, in: next) {
            selectedItemID = defaultSelection(in: next)
        }
    }

    public func selectMailbox(_ mailboxID: Mailbox.ID) {
        for section in sections {
            for item in section.items {
                if case .mailbox(let id, _) = item.kind, id == mailboxID {
                    selectedItemID = item.id
                    return
                }
            }
        }
    }

    public func mailboxID(for itemID: SidebarItem.ID?) -> Mailbox.ID? {
        guard let itemID else { return nil }
        for section in sections {
            for item in section.items where item.id == itemID {
                if case .mailbox(let mailboxID, _) = item.kind {
                    return mailboxID
                }
            }
        }
        return nil
    }

    public func item(for id: SidebarItem.ID) -> SidebarItem? {
        for section in sections {
            if let found = section.items.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    private func defaultSelection(in sections: [SidebarSection]) -> SidebarItem.ID? {
        for section in sections where section.id == .account {
            for item in section.items {
                if case .mailbox(_, let role) = item.kind, role == .inbox {
                    return item.id
                }
            }
            return section.items.first?.id
        }
        return nil
    }

    private func contains(itemID: SidebarItem.ID?, in sections: [SidebarSection]) -> Bool {
        guard let itemID else { return false }
        for section in sections {
            if section.items.contains(where: { $0.id == itemID }) { return true }
        }
        return false
    }
}
