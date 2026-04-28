import Foundation
import Core

@MainActor
public final class SidebarViewModel: ObservableObject {
    @Published public private(set) var sections: [SidebarSection] = []
    @Published public var selectedItemID: SidebarItem.ID?

    // MARK: - MailAi-6xac: Folder management dialog state

    /// Показывать диалог создания новой папки.
    @Published public var showCreateFolderDialog: Bool = false
    /// Путь родительской папки для создания. nil — создать в корне.
    @Published public var pendingParentPath: String?

    /// Показывать диалог переименования папки.
    @Published public var showRenameFolderDialog: Bool = false
    /// ID папки, которую переименовываем.
    @Published public var pendingRenameMailboxID: Mailbox.ID?
    /// Текущее имя папки для отображения в диалоге.
    @Published public var pendingRenameCurrent: String?

    /// Имя папки после подтверждения в диалоге (out-параметр для вызывающей стороны).
    @Published public var pendingFolderName: String?

    public let account: Account
    private let provider: any SidebarProvider

    /// Кеш путей по mailboxID — заполняется в `rebuild`.
    private var pathCache: [Mailbox.ID: String] = [:]

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
        // Обновляем кеш путей
        buildPathCache(from: mailboxes)
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

    // MARK: - MailAi-6xac: Path lookup

    /// Возвращает IMAP-путь папки по её ID. nil — путь не найден в кеше.
    public func path(for mailboxID: Mailbox.ID) -> String? {
        pathCache[mailboxID]
    }

    // MARK: - MailAi-6xac: Dialog triggers

    /// Открывает диалог создания новой папки.
    /// - Parameter parentPath: Путь родительской папки. nil — создать в корне.
    public func beginCreateFolder(parentPath: String?) {
        pendingParentPath = parentPath
        pendingFolderName = nil
        showCreateFolderDialog = true
    }

    /// Открывает диалог переименования папки.
    public func beginRenameFolder(mailboxID: Mailbox.ID, currentName: String) {
        pendingRenameMailboxID = mailboxID
        pendingRenameCurrent = currentName
        pendingFolderName = nil
        showRenameFolderDialog = true
    }

    // MARK: - Private

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

    private func buildPathCache(from mailboxes: [Mailbox]) {
        pathCache.removeAll()
        for mailbox in mailboxes {
            pathCache[mailbox.id] = mailbox.path
            for child in mailbox.children {
                pathCache[child.id] = child.path
            }
        }
    }
}
