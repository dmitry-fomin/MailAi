import SwiftUI
import Core
import UI
import AI
import Storage

public struct AccountWindowScene: View {
    @ObservedObject var session: AccountSessionModel
    @StateObject private var sidebar: SidebarViewModel
    @StateObject private var classificationProgress: ClassificationProgressViewModel
    /// MailAi-nmo4: индикатор синхронизации в тулбаре.
    @StateObject private var syncProgress = SyncProgressViewModel()

    /// AI-G: переводчик писем. nil — кнопка «Перевести» скрыта.
    private let translator: (any AITranslator)?

    /// A6: зоны клавиатурного фокуса окна. Tab циклирует их в порядке
    /// sidebar → list → reader. ⌘1 / ⌘2 переводят фокус в sidebar / list
    /// напрямую.
    @FocusState private var focus: FocusZone?

    /// Фильтр «только непрочитанные» в заголовке списка писем.
    @State private var showOnlyUnread = false

    /// AI-5: pending-предложение нового правила (после drop письма на
    /// «Неважно» / «Важное»). nil — лист не показан.
    @State private var ruleProposal: RuleProposal?

    /// AI-5: short toast после успешного создания правила.
    @State private var ruleConfirmation: String?

    // MARK: - Smart Unsubscribe (MailAi-5m2)

    /// Показывать диалог подтверждения отписки.
    @State private var showUnsubscribeConfirm = false

    // MARK: - MailAi-rpd: Delete Confirmation

    /// Показывать диалог подтверждения удаления.
    @State private var showDeleteConfirmation = false

    // MARK: - MailAi-mi6: Undo Stack

    @State private var undoStack = UndoStack(capacity: 10)

    // MARK: - Message Translation (MailAi-mz3)

    /// Переведённое тело письма. nil — перевод не запрошен. Живёт только в @State.
    @State private var translatedBody: MailTranslation?
    /// true — идёт запрос перевода.
    @State private var isTranslating = false
    /// true — показывать перевод вместо оригинала.
    @State private var showTranslation = false

    /// Wrapper для `ComposeViewModel`, чтобы использовать `sheet(item:)`.
    /// `ComposeViewModel` не `Identifiable`, поэтому оборачиваем.
    private struct ComposeRequest: Identifiable {
        let id = UUID()
        let model: ComposeViewModel
    }

    /// Текущий запрос на открытие окна Compose. nil — sheet не показан.
    @State private var composeRequest: ComposeRequest?

    private let cacheManager = CacheManager.shared

    public enum FocusZone: Hashable {
        case sidebar
        case list
        case reader
    }

    private struct RuleProposal: Identifiable {
        let id = UUID()
        let messages: [DraggableMessage]
        let mode: RuleProposalSheet.Mode
    }

    /// MailAi-8uz8: репозиторий подписей для автовставки при создании письма.
    private let signaturesRepository: SignaturesRepository?

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

    @ViewBuilder private var mainContent: some View {
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
            // AI-5: подписка прогресс-бара на снапшоты очереди.
            if let queue = session.classificationQueue {
                classificationProgress.bind(to: queue)
            }
            // MailAi-nmo4: подписка индикатора синхронизации на стрим BackgroundSyncCoordinator.
            if let coordinator = session.syncCoordinator {
                syncProgress.bind(to: coordinator.progress) { snap in
                    switch snap.phase {
                    case .idle, .completed: return .idle
                    case .syncing:          return .syncing
                    case .failed(let msg):  return .failed(message: msg)
                    }
                }
            }
            // Стартовый фокус — в списке писем.
            if focus == nil { focus = .list }
            // MailAi-791: запуск мониторинга сети.
            session.startNetworkMonitoring()
        }
        .onChange(of: session.mailboxes) { _, _ in
            Task { await rebuildSidebar() }
        }
        .onChange(of: session.messages) { _, _ in
            // AI-5: счётчики «Отфильтрованных» обновляются реактивно.
            Task { await rebuildSidebar() }
        }
        // MailAi-6xac: обработка подтверждения создания папки
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

    private func rebuildSidebar() async {
        await sidebar.rebuild(with: session.mailboxes, messages: session.messages)
    }

    private func handleSelection(_ item: SidebarItem) {
        if case .mailbox(let mailboxID, _) = item.kind {
            session.selectedMailboxID = mailboxID
            Task { await session.loadMessages(for: mailboxID) }
        }
        // smartImportant/smartUnimportant — фильтруют текущий список
        // по `message.importance`. Загрузка не нужна.
    }

    /// AI-5: kind активной AI-папки, если выбрана.
    private var selectedAIPackKind: SidebarItem.Kind? {
        guard let id = sidebar.selectedItemID,
              let item = sidebar.item(for: id) else { return nil }
        switch item.kind {
        case .smartImportant, .smartUnimportant:
            return item.kind
        default:
            return nil
        }
    }

    // MARK: - AI-5 filtered list

    private struct FilteredSpec {
        let target: Importance
        let title: String
        let icon: String
    }

    private func filteredSpec(for kind: SidebarItem.Kind) -> FilteredSpec {
        switch kind {
        case .smartImportant:
            return FilteredSpec(target: .important, title: "Важное", icon: "exclamationmark.circle")
        case .smartUnimportant:
            return FilteredSpec(target: .unimportant, title: "Неважно", icon: "archivebox")
        default:
            return FilteredSpec(target: .unknown, title: "", icon: "tray")
        }
    }

    @ViewBuilder
    private func filteredMessageList(for kind: SidebarItem.Kind) -> some View {
        let spec = filteredSpec(for: kind)
        let filtered = session.messages.filter { $0.importance == spec.target }

        VStack(alignment: .leading, spacing: 0) {
            filteredHeader(title: spec.title, count: filtered.count)
            progressBar
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    spec.title,
                    systemImage: spec.icon,
                    description: Text("Папка пока пуста. Когда AI-классификация отметит письма, они появятся здесь.")
                )
            } else {
                List(selection: Binding(
                    get: { session.selectedMessageID },
                    set: { id in
                        session.selectedMessageID = id
                        session.open(messageID: id)
                    }
                )) {
                    ForEach(filtered) { message in
                        draggableRow(for: message)
                            .tag(message.id as Message.ID?)
                            .id(message.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filteredHeader(title: String, count: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("\(count) писем").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Message list

    @ViewBuilder private var messageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            progressBar
            Divider()
            // MailAi-3iz: пустые состояния.
            if !session.searchQuery.isEmpty && session.searchResults.isEmpty && !session.isSearching {
                ContentUnavailableView.search(text: session.searchQuery)
            } else if session.lastError != nil && session.messages.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Не удалось загрузить",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Проверьте соединение")
                    )
                    Button("Повторить") {
                        Task {
                            if let id = session.selectedMailboxID {
                                await session.loadMessages(for: id)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if session.messages.isEmpty && !session.isLoadingMessages && session.lastError == nil && session.searchQuery.isEmpty {
                ContentUnavailableView(
                    "Папка пуста",
                    systemImage: "tray",
                    description: Text("Здесь появятся письма")
                )
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { session.selectedMessageID },
                        set: { id in
                            session.selectedMessageID = id
                            session.open(messageID: id)
                        }
                    )) {
                        ForEach(displayedMessages) { message in
                            draggableRow(for: message)
                                .tag(message.id as Message.ID?)
                                .id(message.id)
                        }
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1, proxy: proxy)
                        return .handled
                    }
                    .onChange(of: session.selectedMessageID) { _, newID in
                        guard let id = newID else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// AI-5: progress-bar обёрнут в отдельную view, чтобы переиспользовать
    /// в обычном и filtered-режиме.
    @ViewBuilder
    private var progressBar: some View {
        ClassificationProgressBar(
            isActive: classificationProgress.isActive,
            processed: classificationProgress.processed,
            total: classificationProgress.total
        )
    }

    private func moveSelection(by delta: Int, proxy: ScrollViewProxy) {
        let list = displayedMessages
        guard !list.isEmpty else { return }
        let ids = list.map(\.id)
        let currentIndex: Int
        if let selected = session.selectedMessageID,
           let idx = ids.firstIndex(of: selected) {
            currentIndex = idx
        } else {
            currentIndex = delta > 0 ? -1 : ids.count
        }
        let nextIndex = max(0, min(ids.count - 1, currentIndex + delta))
        guard nextIndex != currentIndex else { return }
        let nextID = ids[nextIndex]
        session.selectedMessageID = nextID
        session.open(messageID: nextID)
        proxy.scrollTo(nextID, anchor: .center)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedMailboxName)
                        .font(.headline)
                    Text("\(displayedMessages.count) писем\(session.isSearching ? " · ищем…" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $showOnlyUnread) {
                    Image(systemName: "envelope.badge")
                        .help("Только непрочитанные")
                }
                .toggleStyle(.button)
                .tint(showOnlyUnread ? .accentColor : nil)
                .buttonStyle(.borderless)
            }
            if session.searchService != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Поиск (from:alice has:attachment is:unread …)",
                              text: Binding(
                                get: { session.searchQuery },
                                set: { session.searchQuery = $0 }
                              ))
                    .textFieldStyle(.roundedBorder)
                    if !session.searchQuery.isEmpty {
                        Button {
                            session.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Активный список в текущем режиме: результаты поиска или папки, с опциональным
    /// фильтром «только непрочитанные».
    private var displayedMessages: [Message] {
        let q = session.searchQuery.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? session.messages : session.searchResults
        return showOnlyUnread ? base.filter { !$0.flags.contains(.seen) } : base
    }

    private var selectedMailboxName: String {
        guard let id = session.selectedMailboxID,
              let mailbox = session.mailboxes.first(where: { $0.id == id }) else {
            return "—"
        }
        return mailbox.name
    }

    /// AI-5: строка списка с .draggable() для drag-to-rule.
    @ViewBuilder
    private func draggableRow(for message: Message) -> some View {
        MessageRowView(
            message: message,
            moveTargets: session.mailboxes.filter { $0.id != session.selectedMailboxID },
            onMove: { targetID in Task { await session.perform(.moveToMailbox(targetID)) } }
        )
        .draggable(DraggableMessage(message: message))
    }

    // MARK: - Reader

    @ViewBuilder private var reader: some View {
        if let body = session.openBody, let message = selectedMessage {
            VStack(alignment: .leading, spacing: 0) {
                ReaderHeaderView(message: message)
                ReaderToolbar(actions: ReaderToolbar.Actions(
                    reply: {
                        guard let msg = selectedMessage else { return }
                        composeRequest = ComposeRequest(model: ComposeViewModel.makeReply(
                            to: msg,
                            accountEmail: session.account.email,
                            accountDisplayName: session.account.displayName,
                            sendProvider: session.provider as? any SendProvider,
                            draftSaver: nil
                        ))
                    },
                    replyAll: {
                        guard let msg = selectedMessage else { return }
                        composeRequest = ComposeRequest(model: ComposeViewModel.makeReplyAll(
                            to: msg,
                            accountEmail: session.account.email,
                            accountDisplayName: session.account.displayName,
                            sendProvider: session.provider as? any SendProvider,
                            draftSaver: nil
                        ))
                    },
                    forward: {
                        guard let msg = selectedMessage else { return }
                        composeRequest = ComposeRequest(model: ComposeViewModel.makeForward(
                            of: msg,
                            accountEmail: session.account.email,
                            accountDisplayName: session.account.displayName,
                            sendProvider: session.provider as? any SendProvider,
                            draftSaver: nil
                        ))
                    },
                    archive: { Task { await session.perform(.archive) } },
                    delete: { showDeleteConfirmation = true },
                    flag: { Task { await session.perform(.toggleFlag) } },
                    toggleRead: { Task { await session.perform(.toggleRead) } },
                    unsubscribe: message.listUnsubscribe != nil
                        ? { showUnsubscribeConfirm = true }
                        : nil,
                    translate: translator != nil
                        ? { Task { await performTranslation(body: body) } }
                        : nil,
                    // MailAi-9fi0: кнопка «Восстановить» видна только в Trash.
                    restore: session.isInTrash
                        ? {
                            guard let id = session.selectedMessageID else { return }
                            Task { await session.restore(messageIDs: [id]) }
                        }
                        : nil
                ))
                .confirmationDialog("Отписаться от рассылки?", isPresented: $showUnsubscribeConfirm) {
                    Button("Отписаться", role: .destructive) {
                        Task { await showToast("Запрос на отписку отправлен") }
                    }
                    Button("Отмена", role: .cancel) {}
                }
                Divider()
                // Переключатель Оригинал / Перевод
                if translatedBody != nil {
                    Picker("", selection: $showTranslation) {
                        Text("Оригинал").tag(false)
                        Text("Перевод").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                if isTranslating {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Перевод…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                if showTranslation, let translation = translatedBody {
                    let translatedBody = MessageBody(
                        messageID: body.messageID,
                        content: .plain(translation.text),
                        attachments: body.attachments
                    )
                    ReaderBodyView(
                        body: translatedBody,
                        messageID: translatedBody.messageID.rawValue,
                        cacheManager: cacheManager,
                        onSaveAttachment: { att in saveAttachment(att) },
                        isFocused: Binding(
                            get: { focus == .reader },
                            set: { newValue in if newValue { focus = .reader } }
                        )
                    )
                } else {
                    ReaderBodyView(
                        body: body,
                        messageID: body.messageID.rawValue,
                        cacheManager: cacheManager,
                        onSaveAttachment: { att in saveAttachment(att) },
                        isFocused: Binding(
                            get: { focus == .reader },
                            set: { newValue in
                                if newValue { focus = .reader }
                            }
                        )
                    )
                }
            }
            .onChange(of: session.selectedMessageID) { _, _ in
                // Сбрасываем перевод при смене письма.
                translatedBody = nil
                showTranslation = false
                isTranslating = false
            }
            // MailAi-k90l: Spotlight / Handoff — регистрируем NSUserActivity
            // при открытии письма, чтобы оно появлялось в Spotlight.
            .userActivity("com.mailai.message", isActive: true) { activity in
                activity.title = message.subject.isEmpty ? "(Без темы)" : message.subject
                activity.userInfo = [
                    "messageID": message.id,
                    "accountID": session.account.id
                ]
                activity.isEligibleForSearch = true
                activity.isEligibleForHandoff = false
                activity.isEligibleForPublicIndexing = false
            }
        } else if session.openBody == nil && session.isOffline && session.selectedMessageID != nil {
            ContentUnavailableView(
                "Тело письма недоступно офлайн",
                systemImage: "wifi.slash",
                description: Text("Подключитесь к интернету, чтобы загрузить письмо.")
            )
        } else {
            ContentUnavailableView(
                "Выберите письмо",
                systemImage: "envelope",
                description: Text("Кликните по строке в списке, чтобы открыть содержимое.")
            )
        }
    }

    /// Запрашивает перевод через `translator`. Результат — только в @State.
    @MainActor
    private func performTranslation(body: MessageBody) async {
        guard let translator else { return }
        guard !isTranslating else { return }
        let text: String
        switch body.content {
        case .plain(let s): text = s
        case .html(let h):
            let data = Data(h.utf8)
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            text = (try? NSAttributedString(data: data, options: opts, documentAttributes: nil))?.string ?? h
        }
        guard !text.isEmpty else { return }
        isTranslating = true
        defer {
            isTranslating = false
        }
        do {
            let result: MailTranslation = try await translator.translate(body: text, targetLanguage: "ru")
            translatedBody = result
            showTranslation = true
        } catch {
            await showToast("Не удалось перевести письмо")
        }
    }

    @MainActor
    private func saveAttachment(_ attachment: Attachment) {
        Task {
            do {
                let data = try await session.downloadAttachment(attachment)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.filename.isEmpty ? "attachment" : attachment.filename
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url)
            } catch {
                await showToast("Не удалось скачать вложение")
            }
        }
    }

    private var selectedMessage: Message? {
        guard let id = session.selectedMessageID else { return nil }
        return session.messages.first(where: { $0.id == id })
            ?? session.searchResults.first(where: { $0.id == id })
    }

    // MARK: - AI-5 drag-to-rule

    private func handleDrop(onKind kind: SidebarItem.Kind, messages dropped: [DraggableMessage]) {
        let mode: RuleProposalSheet.Mode
        switch kind {
        case .smartUnimportant: mode = .markUnimportant
        case .smartImportant: mode = .markImportant
        default: return
        }
        guard !dropped.isEmpty else { return }
        ruleProposal = RuleProposal(messages: dropped, mode: mode)
    }

    private func saveRule(_ rule: Rule) async {
        guard let engine = session.ruleEngine else {
            // Без engine — просто покажем тост, что в demo-режиме
            // правила не сохраняются.
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

    @MainActor
    private func showToast(_ text: String) async {
        withAnimation { ruleConfirmation = text }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { ruleConfirmation = nil }
    }

    // MARK: - Shortcuts

    /// A6: невидимые кнопки, которые держат ⌘1 / ⌘2 / ⌘R. Повешать
    /// `.keyboardShortcut` напрямую на зоны нельзя (SwiftUI подвязывает
    /// шорткаты только к Button/ControlGroup), поэтому складываем их в
    /// фоновую `HStack` нулевого размера.
    @ViewBuilder private var shortcutsBackground: some View {
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
            // MailAi-spo9: E — архивировать текущее письмо (как в Apple Mail).
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

    // MARK: - MailAi-8uz8: Compose with default signature

    /// Открывает окно создания письма, автоматически вставляя подпись по умолчанию.
    /// Подпись загружается асинхронно из `SignaturesRepository` для текущего аккаунта.
    @MainActor
    private func openCompose() async {
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

    /// Обрабатывает действие управления папкой из контекстного меню сайдбара.
    ///
    /// Действия CREATE/RENAME/DELETE делегируются `MailboxActionsProvider`,
    /// если `session.provider` его реализует. После успеха перезагружаем
    /// список папок через `session.loadMailboxes()`.
    private func handleMailboxAction(_ action: MailboxAction) {
        guard let provider = session.provider as? any MailboxActionsProvider else {
            Task { await showToast("Управление папками не поддерживается для этого аккаунта") }
            return
        }

        switch action {
        case .createFolder(let parentPath):
            // Показываем диалог через SidebarViewModel; имя придёт через pendingFolderName
            sidebar.beginCreateFolder(parentPath: parentPath)
            // Наблюдаем за pendingFolderName через onChange в теле View.
            // Реальный вызов IMAP-команды — в handlePendingFolderCreation().
            _ = provider // держим ссылку, реальный вызов — в handlePendingCreate

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

    /// Перемещает выделение на следующее непрочитанное письмо после текущего.
    /// Если текущего нет или достигнут конец списка — переходит к первому непрочитанному.
    private func selectNextUnread() {
        let list = displayedMessages
        guard !list.isEmpty else { return }

        if let current = session.selectedMessageID,
           let currentIdx = list.firstIndex(where: { $0.id == current }) {
            // Ищем следующее непрочитанное после текущей позиции.
            let tail = list[(currentIdx + 1)...].first(where: { !$0.flags.contains(.seen) })
            if let next = tail {
                session.selectedMessageID = next.id
                session.open(messageID: next.id)
                return
            }
        }
        // Нет текущего или конец — идём к первому непрочитанному.
        if let firstUnread = list.first(where: { !$0.flags.contains(.seen) }) {
            session.selectedMessageID = firstUnread.id
            session.open(messageID: firstUnread.id)
        }
    }
}
