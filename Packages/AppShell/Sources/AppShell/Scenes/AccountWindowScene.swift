import SwiftUI
import Core
import UI
import AI

public struct AccountWindowScene: View {
    @ObservedObject var session: AccountSessionModel
    @StateObject private var sidebar: SidebarViewModel
    @StateObject private var classificationProgress: ClassificationProgressViewModel

    /// A6: зоны клавиатурного фокуса окна. Tab циклирует их в порядке
    /// sidebar → list → reader. ⌘1 / ⌘2 переводят фокус в sidebar / list
    /// напрямую.
    @FocusState private var focus: FocusZone?

    /// AI-5: pending-предложение нового правила (после drop письма на
    /// «Неважно» / «Важное»). nil — лист не показан.
    @State private var ruleProposal: RuleProposal?

    /// AI-5: short toast после успешного создания правила.
    @State private var ruleConfirmation: String?

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

    public init(session: AccountSessionModel) {
        self.session = session
        _sidebar = StateObject(wrappedValue: SidebarViewModel(account: session.account))
        _classificationProgress = StateObject(wrappedValue: ClassificationProgressViewModel())
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: sidebar,
                onSelect: { item in handleSelection(item) },
                onDropMessages: { kind, dropped in
                    handleDrop(onKind: kind, messages: dropped)
                }
            )
            .frame(minWidth: 220)
            .focused($focus, equals: .sidebar)
        } content: {
            Group {
                if let kind = selectedAIPackKind {
                    filteredMessageList(for: kind)
                } else {
                    messageList
                }
            }
            .frame(minWidth: 320)
            .focused($focus, equals: .list)
        } detail: {
            reader
                .frame(minWidth: 480)
                .focused($focus, equals: .reader)
        }
        .navigationTitle(session.account.email)
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
            // Стартовый фокус — в списке писем.
            if focus == nil { focus = .list }
        }
        .onChange(of: session.mailboxes) { _, _ in
            Task { await rebuildSidebar() }
        }
        .onChange(of: session.messages) { _, _ in
            // AI-5: счётчики «Отфильтрованных» обновляются реактивно.
            Task { await rebuildSidebar() }
        }
        .onDisappear {
            classificationProgress.unbind()
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
        .padding(.vertical, 8)
    }

    // MARK: - Message list

    @ViewBuilder private var messageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            progressBar
            Divider()
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

    /// Активный список в текущем режиме: результаты поиска или папки.
    private var displayedMessages: [Message] {
        let q = session.searchQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? session.messages : session.searchResults
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
        MessageRowView(message: message)
            .draggable(DraggableMessage(message: message))
    }

    // MARK: - Reader

    @ViewBuilder private var reader: some View {
        if let body = session.openBody, let message = selectedMessage {
            VStack(alignment: .leading, spacing: 0) {
                ReaderHeaderView(message: message)
                ReaderToolbar(actions: ReaderToolbar.Actions(
                    reply: {},
                    replyAll: {},
                    forward: {},
                    archive: { Task { await session.perform(.archive) } },
                    delete: { Task { await session.perform(.delete) } },
                    flag: { Task { await session.perform(.toggleFlag) } },
                    toggleRead: { Task { await session.perform(.toggleRead) } }
                ))
                Divider()
                ReaderBodyView(
                    body: body,
                    isFocused: Binding(
                        get: { focus == .reader },
                        set: { newValue in
                            if newValue { focus = .reader }
                        }
                    )
                )
            }
        } else {
            ContentUnavailableView(
                "Выберите письмо",
                systemImage: "envelope",
                description: Text("Кликните по строке в списке, чтобы открыть содержимое.")
            )
        }
    }

    private var selectedMessage: Message? {
        guard let id = session.selectedMessageID else { return nil }
        return session.messages.first(where: { $0.id == id })
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
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
