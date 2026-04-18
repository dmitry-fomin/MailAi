import SwiftUI
import Core
import UI

public struct AccountWindowScene: View {
    @ObservedObject var session: AccountSessionModel
    @StateObject private var sidebar: SidebarViewModel

    /// A6: зоны клавиатурного фокуса окна. Tab циклирует их в порядке
    /// sidebar → list → reader. ⌘1 / ⌘2 переводят фокус в sidebar / list
    /// напрямую.
    @FocusState private var focus: FocusZone?

    public enum FocusZone: Hashable {
        case sidebar
        case list
        case reader
    }

    public init(session: AccountSessionModel) {
        self.session = session
        _sidebar = StateObject(wrappedValue: SidebarViewModel(account: session.account))
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: sidebar) { item in
                handleSelection(item)
            }
            .frame(minWidth: 220)
            .focused($focus, equals: .sidebar)
        } content: {
            messageList
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
            await sidebar.rebuild(with: session.mailboxes)
            if let mailboxID = sidebar.mailboxID(for: sidebar.selectedItemID) {
                session.selectedMailboxID = mailboxID
                await session.loadMessages(for: mailboxID)
            }
            // Стартовый фокус — в списке писем.
            if focus == nil { focus = .list }
        }
        .onChange(of: session.mailboxes) { _, newValue in
            Task { await sidebar.rebuild(with: newValue) }
        }
        .onDisappear {
            session.closeSession()
        }
    }

    private func handleSelection(_ item: SidebarItem) {
        if case .mailbox(let mailboxID, _) = item.kind {
            session.selectedMailboxID = mailboxID
            Task { await session.loadMessages(for: mailboxID) }
        }
    }

    // MARK: - Message list

    @ViewBuilder private var messageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Зарезервированный слот под прогресс-бар фоновой синхронизации
            // (см. критерии приёмки SPECIFICATION.md).
            Color.clear.frame(height: 0)
            Divider()
            ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { session.selectedMessageID },
                    set: { id in
                        session.selectedMessageID = id
                        session.open(messageID: id)
                    }
                )) {
                    ForEach(session.messages) { message in
                        row(for: message)
                            .tag(message.id as Message.ID?)
                            .id(message.id)
                    }
                }
                // A6: ↑/↓ двигают selection и подкручивают ряд в видимую область.
                // SwiftUI-`List` сам обрабатывает стрелки, когда в фокусе, но
                // при этом не всегда скроллит к выбранному ряду — дублируем
                // явным handler'ом с `scrollTo`.
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

    private func moveSelection(by delta: Int, proxy: ScrollViewProxy) {
        guard !session.messages.isEmpty else { return }
        let ids = session.messages.map(\.id)
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedMailboxName)
                    .font(.headline)
                Text("\(session.messages.count) писем")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectedMailboxName: String {
        guard let id = session.selectedMailboxID,
              let mailbox = session.mailboxes.first(where: { $0.id == id }) else {
            return "—"
        }
        return mailbox.name
    }

    @ViewBuilder private func row(for message: Message) -> some View {
        MessageRowView(message: message)
    }

    // MARK: - Reader

    @ViewBuilder private var reader: some View {
        if let body = session.openBody, let message = selectedMessage {
            VStack(alignment: .leading, spacing: 0) {
                ReaderHeaderView(message: message)
                ReaderToolbar()
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
                // TODO(A6/B-phase): noop. Интеграция с провайдером будет
                // сделана в фазе B (refetch mailboxes + messages).
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
