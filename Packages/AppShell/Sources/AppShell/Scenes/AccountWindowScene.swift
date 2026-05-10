import SwiftUI
import Core
import UI
import AI
import Storage

public struct AccountWindowScene: View {
    @ObservedObject var session: AccountSessionModel
    @StateObject var sidebar: SidebarViewModel
    @StateObject var classificationProgress: ClassificationProgressViewModel
    /// MailAi-nmo4: индикатор синхронизации в тулбаре.
    @StateObject var syncProgress = SyncProgressViewModel()

    /// AI-G: переводчик писем. nil — кнопка «Перевести» скрыта.
    let translator: (any AITranslator)?

    /// A6: зоны клавиатурного фокуса окна.
    @FocusState var focus: FocusZone?

    /// Фильтр «только непрочитанные» в заголовке списка писем.
    @State var showOnlyUnread = false

    /// AI-5: pending-предложение нового правила. nil — лист не показан.
    @State var ruleProposal: RuleProposal?

    /// AI-5: short toast после успешного создания правила.
    @State var ruleConfirmation: String?

    // MARK: - Smart Unsubscribe (MailAi-5m2)

    @State var showUnsubscribeConfirm = false

    // MARK: - MailAi-rpd: Delete Confirmation

    @State var showDeleteConfirmation = false

    // MARK: - MailAi-mi6: Undo Stack

    @State var undoStack = UndoStack(capacity: 10)

    // MARK: - Message Translation (MailAi-mz3)

    @State var translatedBody: MailTranslation?
    @State var isTranslating = false
    @State var showTranslation = false

    struct ComposeRequest: Identifiable {
        let id = UUID()
        let model: ComposeViewModel
    }

    @State var composeRequest: ComposeRequest?

    let cacheManager = CacheManager.shared

    public enum FocusZone: Hashable {
        case sidebar
        case list
        case reader
    }

    struct RuleProposal: Identifiable {
        let id = UUID()
        let messages: [DraggableMessage]
        let mode: RuleProposalSheet.Mode
    }

    /// MailAi-8uz8: репозиторий подписей для автовставки при создании письма.
    let signaturesRepository: SignaturesRepository?

    public init(
        session: AccountSessionModel,
        translator: (any AITranslator)? = nil,
        signaturesRepository: SignaturesRepository? = nil
    ) {
        self.session = session
        self.translator = translator
        self.signaturesRepository = signaturesRepository
        _sidebar = StateObject(wrappedValue: SidebarViewModel(account: session.account))
        _classificationProgress = StateObject(wrappedValue: ClassificationProgressViewModel())
    }

    public var body: some View {
        mainContent
            .mailKeyboardShortcuts(
                onReply: {
                    guard let msg = selectedMessage else { return }
                    composeRequest = ComposeRequest(model: ComposeViewModel.makeReply(
                        to: msg,
                        accountEmail: session.account.email,
                        accountDisplayName: session.account.displayName,
                        sendProvider: session.provider as? any SendProvider,
                        draftSaver: nil
                    ))
                },
                onReplyAll: {
                    guard let msg = selectedMessage else { return }
                    composeRequest = ComposeRequest(model: ComposeViewModel.makeReplyAll(
                        to: msg,
                        accountEmail: session.account.email,
                        accountDisplayName: session.account.displayName,
                        sendProvider: session.provider as? any SendProvider,
                        draftSaver: nil
                    ))
                },
                onForward: {
                    guard let msg = selectedMessage else { return }
                    composeRequest = ComposeRequest(model: ComposeViewModel.makeForward(
                        of: msg,
                        accountEmail: session.account.email,
                        accountDisplayName: session.account.displayName,
                        sendProvider: session.provider as? any SendProvider,
                        draftSaver: nil
                    ))
                },
                onArchive: { Task { await session.perform(.archive) } },
                onDelete: { showDeleteConfirmation = true },
                onNextUnread: { selectNextUnread() },
                onCompose: {
                    Task { await openCompose() }
                },
                onFocusSearch: { focus = .list }
            )
    }

    // MARK: - Main layout

    @ViewBuilder var mainContent: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: sidebar,
                onSelect: { item in handleSelection(item) },
                onDropMessages: { kind, dropped in
                    handleDrop(onKind: kind, messages: dropped)
                },
                onMailboxAction: { action in
                    handleMailboxAction(action)
                }
            )
            .frame(minWidth: 200)
            .focused($focus, equals: .sidebar)
        } content: {
            Group {
                if let kind = selectedAIPackKind {
                    filteredMessageList(for: kind)
                } else {
                    messageList
                }
            }
            .frame(minWidth: 280)
            .focused($focus, equals: .list)
        } detail: {
            reader
                .frame(minWidth: 400)
                .focused($focus, equals: .reader)
        }
        .navigationTitle(session.account.email)
        .toolbar {
            // MailAi-nmo4: индикатор синхронизации — виден только при активном sync.
            ToolbarItem(placement: .status) {
                SyncStatusIndicator(phase: syncProgress.phase)
                    .animation(.easeInOut(duration: 0.2), value: syncProgress.phase)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // MailAi-791: офлайн-баннер.
            if session.isOffline {
                HStack {
                    Image(systemName: "wifi.slash")
                    Text("Нет подключения — показаны кешированные данные")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.9))
                .frame(maxWidth: .infinity)
            }
        }
        .background(shortcutsBackground)
        .task {
            await session.loadMailboxes()
            await rebuildSidebar()
            if let mailboxID = sidebar.mailboxID(for: sidebar.selectedItemID) {
                session.selectedMailboxID = mailboxID
                await session.loadMessages(for: mailboxID)
            }
            if let queue = session.classificationQueue {
                classificationProgress.bind(to: queue)
            }
            // MailAi-nmo4: подписка индикатора синхронизации.
            if let coordinator = session.syncCoordinator {
                syncProgress.bind(to: coordinator.progress) { snap in
                    switch snap.phase {
                    case .idle, .completed: return .idle
                    case .syncing:          return .syncing
                    case .failed(let msg):  return .failed(message: msg)
                    }
                }
            }
            if focus == nil { focus = .list }
            // MailAi-791: запуск мониторинга сети.
            session.startNetworkMonitoring()
        }
        .onChange(of: session.mailboxes) { _, _ in
            Task { await rebuildSidebar() }
        }
        .onChange(of: session.messages) { _, _ in
            Task { await rebuildSidebar() }
        }
        // MailAi-6xac: обработка подтверждения создания/переименования папки
        .onChange(of: sidebar.pendingFolderName) { _, newName in
            guard let name = newName, !name.isEmpty else { return }
            if sidebar.showCreateFolderDialog == false,
               let provider = session.provider as? any MailboxActionsProvider {
                let parentPath = sidebar.pendingParentPath
                Task {
                    do {
                        _ = try await provider.createMailbox(name: name, parentPath: parentPath)
                        await session.loadMailboxes()
                        await showToast("Папка «\(name)» создана")
                    } catch {
                        await showToast("Не удалось создать папку «\(name)»")
                    }
                    sidebar.pendingFolderName = nil
                }
            } else if sidebar.showRenameFolderDialog == false,
                      let provider = session.provider as? any MailboxActionsProvider,
                      let mailboxID = sidebar.pendingRenameMailboxID {
                Task {
                    do {
                        try await provider.renameMailbox(mailboxID: mailboxID, newName: name)
                        await session.loadMailboxes()
                        await showToast("Папка переименована в «\(name)»")
                    } catch {
                        await showToast("Не удалось переименовать папку")
                    }
                    sidebar.pendingFolderName = nil
                }
            }
        }
        .onDisappear {
            classificationProgress.unbind()
            syncProgress.unbind()
            session.stopNetworkMonitoring()
            session.closeSession()
        }
        .sheet(item: $ruleProposal) { proposal in
            RuleProposalSheet(
                messages: proposal.messages,
                mode: proposal.mode,
                onConfirm: { rule in
                    await saveRule(rule)
                    ruleProposal = nil
                },
                onCancel: { ruleProposal = nil }
            )
        }
        .sheet(item: $composeRequest) { request in
            ComposeScene(model: request.model, onClose: { composeRequest = nil })
        }
        .confirmationDialog("Удалить письмо?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                Task { await session.perform(.delete) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if let toast = ruleConfirmation {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    func rebuildSidebar() async {
        await sidebar.rebuild(with: session.mailboxes, messages: session.messages)
    }

    func handleSelection(_ item: SidebarItem) {
        if case .mailbox(let mailboxID, _) = item.kind {
            session.selectedMailboxID = mailboxID
            Task { await session.loadMessages(for: mailboxID) }
        }
    }

    /// AI-5: kind активной AI-папки, если выбрана.
    var selectedAIPackKind: SidebarItem.Kind? {
        guard let id = sidebar.selectedItemID,
              let item = sidebar.item(for: id) else { return nil }
        switch item.kind {
        case .smartImportant, .smartUnimportant:
            return item.kind
        default:
            return nil
        }
    }

    @MainActor
    func showToast(_ text: String) async {
        withAnimation { ruleConfirmation = text }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { ruleConfirmation = nil }
    }

    // MARK: - Shortcuts

    /// A6: невидимые кнопки для ⌘1 / ⌘2 / ⌘R / ⌘Z / E / ⌘⇧U.
    @ViewBuilder var shortcutsBackground: some View {
        HStack(spacing: 0) {
            Button("Focus Sidebar") { focus = .sidebar }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Focus List") { focus = .list }
                .keyboardShortcut("2", modifiers: [.command])
            Button("Refresh") {
                if let mailboxID = session.selectedMailboxID {
                    Task { await session.loadMessages(for: mailboxID) }
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            // MailAi-mi6: ⌘Z — отмена последнего действия.
            Button("Undo") {
                Task {
                    let action = await undoStack.pop()
                    guard action != nil else { return }
                    await showToast("Отменено")
                }
            }
            .keyboardShortcut("z", modifiers: [.command])
            // MailAi-spo9: E — архивировать текущее письмо.
            Button("Archive") {
                Task { await session.perform(.archive) }
            }
            .keyboardShortcut("e", modifiers: [])
            .disabled(session.selectedMessageID == nil)
            // MailAi-9fi0: Восстановить из Trash.
            Button("Restore from Trash") {
                guard let id = session.selectedMessageID else { return }
                Task { await session.restore(messageIDs: [id]) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!session.isInTrash || session.selectedMessageID == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
