import SwiftUI
import Core
import Storage

extension AccountWindowScene {

    // MARK: - AI-5 drag-to-rule

    func handleDrop(onKind kind: SidebarItem.Kind, messages dropped: [DraggableMessage]) {
        let mode: RuleProposalSheet.Mode
        switch kind {
        case .smartUnimportant: mode = .markUnimportant
        case .smartImportant: mode = .markImportant
        default: return
        }
        guard !dropped.isEmpty else { return }
        ruleProposal = RuleProposal(messages: dropped, mode: mode)
    }

    func saveRule(_ rule: Rule) async {
        guard let engine = session.ruleEngine else {
            await showToast("AI-pack отключён, правило не сохранено")
            return
        }
        do {
            try await engine.save(rule)
            await showToast(rule.intent == .markImportant
                            ? "Правило «Важное» создано"
                            : "Правило «Неважно» создано")
        } catch {
            await showToast("Не удалось сохранить правило")
        }
    }

    // MARK: - MailAi-8uz8: Compose with default signature

    @MainActor
    func openCompose() async {
        let defaultSigBody: String?
        if let repo = signaturesRepository {
            let sig = try? await repo.defaultSignature(for: session.account.id)
            defaultSigBody = sig?.body
        } else {
            defaultSigBody = nil
        }
        composeRequest = ComposeRequest(model: ComposeViewModel(
            accountEmail: session.account.email,
            accountDisplayName: session.account.displayName,
            sendProvider: session.provider as? any SendProvider,
            draftSaver: nil,
            defaultSignatureBody: defaultSigBody
        ))
    }

    // MARK: - MailAi-6xac: Mailbox folder management

    func handleMailboxAction(_ action: MailboxAction) {
        guard let provider = session.provider as? any MailboxActionsProvider else {
            Task { await showToast("Управление папками не поддерживается для этого аккаунта") }
            return
        }

        switch action {
        case .createFolder(let parentPath):
            sidebar.beginCreateFolder(parentPath: parentPath)
            _ = provider

        case .renameFolder(let mailboxID, let currentName):
            sidebar.beginRenameFolder(mailboxID: mailboxID, currentName: currentName)
            _ = provider

        case .deleteFolder(let mailboxID, let name):
            let mailboxActions = provider
            Task {
                do {
                    try await mailboxActions.deleteMailbox(mailboxID: mailboxID)
                    await session.loadMailboxes()
                    await showToast("Папка «\(name)» удалена")
                } catch {
                    await showToast("Не удалось удалить папку «\(name)»")
                }
            }
        }
    }

    // MARK: - Next Unread (Space)

    func selectNextUnread() {
        let list = displayedMessages
        guard !list.isEmpty else { return }

        if let current = session.selectedMessageID,
           let currentIdx = list.firstIndex(where: { $0.id == current }) {
            let tail = list[(currentIdx + 1)...].first(where: { !$0.flags.contains(.seen) })
            if let next = tail {
                session.selectedMessageID = next.id
                session.open(messageID: next.id)
                return
            }
        }
        if let firstUnread = list.first(where: { !$0.flags.contains(.seen) }) {
            session.selectedMessageID = firstUnread.id
            session.open(messageID: firstUnread.id)
        }
    }
}
