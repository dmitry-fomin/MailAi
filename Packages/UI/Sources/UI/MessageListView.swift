import SwiftUI
import Core

// MARK: - MessageListViewModel

/// ViewModel для списка писем с пагинацией.
///
/// Хранит загруженные сообщения и управляет load-more при прокрутке к концу.
/// Изолирован на `@MainActor`, так как напрямую публикует изменения для UI.
@MainActor
public final class MessageListViewModel: ObservableObject {

    // MARK: - Published state

    /// Текущий отображаемый список писем.
    @Published public private(set) var messages: [Message] = []
    /// `true` — идёт загрузка следующей страницы.
    @Published public private(set) var isLoadingMore: Bool = false
    /// `true` — все страницы загружены, больше данных нет.
    @Published public private(set) var hasMore: Bool = true

    // MARK: - Configuration

    /// Размер одной страницы.
    public let pageSize: Int

    // MARK: - Callbacks

    /// Провайдер следующей страницы. Получает offset и limit, возвращает
    /// новые письма. Пустой массив означает конец данных.
    public var loadPage: ((_ offset: Int, _ limit: Int) async throws -> [Message])?

    /// Callback при выборе письма.
    public var onSelect: ((Message.ID?) -> Void)?

    // MARK: - Init

    public init(pageSize: Int = 50) {
        self.pageSize = pageSize
    }

    // MARK: - Public API

    /// Сбрасывает список и загружает первую страницу.
    public func reload() {
        messages = []
        hasMore = true
        Task { await loadNextPage() }
    }

    /// Добавляет письма сверху (например, из IDLE-нотификации).
    /// Дубликаты по `id` не добавляются.
    public func prepend(_ newMessages: [Message]) {
        let existingIDs = Set(messages.map(\.id))
        let fresh = newMessages.filter { !existingIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages.insert(contentsOf: fresh, at: 0)
    }

    /// Загружает следующую страницу, если ещё есть данные и не идёт загрузка.
    public func loadMoreIfNeeded() {
        guard hasMore, !isLoadingMore else { return }
        Task { await loadNextPage() }
    }

    // MARK: - Private

    private func loadNextPage() async {
        guard hasMore, !isLoadingMore, let loadPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let offset = messages.count
        do {
            let page = try await loadPage(offset, pageSize)
            if page.isEmpty {
                hasMore = false
            } else {
                // Исключаем дубликаты на случай race condition.
                let existingIDs = Set(messages.map(\.id))
                let unique = page.filter { !existingIDs.contains($0.id) }
                messages.append(contentsOf: unique)
                if unique.count < pageSize {
                    hasMore = false
                }
            }
        } catch {
            // Ошибку загрузки не стираем список — просто останавливаем пагинацию.
            hasMore = false
        }
    }
}

// MARK: - BatchSelectionState

/// Состояние multi-select режима для `MessageListView`.
///
/// Хранит набор выбранных ID. Используется как `@StateObject` / `@ObservedObject`
/// в родительском view — передаётся в список и batch toolbar.
@MainActor
public final class BatchSelectionState: ObservableObject {
    @Published public private(set) var selectedIDs: Set<Message.ID> = []
    @Published public private(set) var isActive: Bool = false

    public init() {}

    /// Активирует режим multi-select.
    public func activate() { isActive = true }

    /// Деактивирует режим multi-select и снимает весь выбор.
    public func deactivate() { isActive = false; selectedIDs = [] }

    /// Добавляет / убирает письмо из выбора.
    public func toggle(_ id: Message.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// Выбирает все переданные письма.
    public func selectAll(_ messages: [Message]) {
        selectedIDs = Set(messages.map(\.id))
    }

    /// Снимает весь выбор (не деактивирует режим).
    public func clear() { selectedIDs = [] }

    public var selectionCount: Int { selectedIDs.count }
    public var hasSelection: Bool { !selectedIDs.isEmpty }
}

// MARK: - BatchToolbar

/// Toolbar с batch-кнопками, появляется при активном multi-select режиме.
///
/// Кнопки: прочитано, непрочитано, флаг, удалить, архивировать, переместить,
/// снять выбор.
public struct BatchToolbar: View {
    @ObservedObject public var state: BatchSelectionState
    public var mailboxes: [Mailbox]
    public var onMarkRead: () -> Void
    public var onMarkUnread: () -> Void
    public var onFlag: () -> Void
    public var onDelete: () -> Void
    public var onArchive: () -> Void
    public var onMove: ((Mailbox.ID) -> Void)?

    public init(
        state: BatchSelectionState,
        mailboxes: [Mailbox] = [],
        onMarkRead: @escaping () -> Void = {},
        onMarkUnread: @escaping () -> Void = {},
        onFlag: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onArchive: @escaping () -> Void = {},
        onMove: ((Mailbox.ID) -> Void)? = nil
    ) {
        self.state = state
        self.mailboxes = mailboxes
        self.onMarkRead = onMarkRead
        self.onMarkUnread = onMarkUnread
        self.onFlag = onFlag
        self.onDelete = onDelete
        self.onArchive = onArchive
        self.onMove = onMove
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text("\(state.selectionCount) выбрано")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Spacer()

            batchButton("envelope.open", "Прочитано", action: onMarkRead)
            batchButton("envelope", "Непрочитано", action: onMarkUnread)
            batchButton("flag", "Флаг", action: onFlag)

            Divider().frame(height: 16).padding(.horizontal, 2)

            batchButton("archivebox", "Архивировать", action: onArchive)

            if let onMove, !mailboxes.isEmpty {
                Menu {
                    ForEach(mailboxes) { mailbox in
                        Button(mailbox.name) { onMove(mailbox.id) }
                    }
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .help("Переместить в…")
                .frame(width: 28)
            }

            batchButton("trash", "Удалить", action: onDelete)
                .foregroundStyle(.red)

            Divider().frame(height: 16).padding(.horizontal, 2)

            Button {
                state.deactivate()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Снять выбор")
            .accessibilityLabel("Снять выбор")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private func batchButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(!state.hasSelection)
    }
}

// MARK: - MessageListView

/// Список писем с виртуализацией через `List` и пагинацией (load-more
/// при скролле к концу). Поддерживает multi-select через `BatchSelectionState`.
///
/// Каждая строка реализована через `MessageRowView`:
/// отправитель, тема, превью, дата, unread indicator.
///
/// Пагинация запускается автоматически, когда пользователь прокручивает
/// до последних `prefetchThreshold` строк.
public struct MessageListView: View {

    @ObservedObject public var viewModel: MessageListViewModel

    /// Биндинг на выбранное письмо для интеграции с `NavigationSplitView`.
    @Binding public var selection: Message.ID?

    /// Количество строк от конца списка, при достижении которых начинается
    /// prefetch следующей страницы.
    public var prefetchThreshold: Int

    /// Список папок для контекстного меню «Переместить в…».
    public var moveTargets: [Mailbox]

    /// Callback при перемещении письма в другую папку.
    public var onMove: ((Message.ID, Mailbox.ID) -> Void)?

    /// Опциональное состояние multi-select. Если nil — режим выбора отключён.
    public var batchSelection: BatchSelectionState?

    public init(
        viewModel: MessageListViewModel,
        selection: Binding<Message.ID?>,
        prefetchThreshold: Int = 10,
        moveTargets: [Mailbox] = [],
        onMove: ((Message.ID, Mailbox.ID) -> Void)? = nil,
        batchSelection: BatchSelectionState? = nil
    ) {
        self.viewModel = viewModel
        self._selection = selection
        self.prefetchThreshold = prefetchThreshold
        self.moveTargets = moveTargets
        self.onMove = onMove
        self.batchSelection = batchSelection
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(viewModel.messages) { message in
                messageRow(message)
                    .tag(message.id as Message.ID?)
                    .id(message.id)
                    .onAppear {
                        triggerPrefetchIfNeeded(for: message)
                    }
            }

            // Индикатор загрузки в конце списка.
            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.vertical, 8)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .onAppear {
            // Первая загрузка, если список пуст.
            if viewModel.messages.isEmpty && viewModel.hasMore && !viewModel.isLoadingMore {
                viewModel.loadMoreIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: Message) -> some View {
        if let batch = batchSelection, batch.isActive {
            // Multi-select режим: показываем чекбокс + строку письма.
            HStack(spacing: 6) {
                Image(systemName: batch.selectedIDs.contains(message.id)
                    ? "checkmark.circle.fill"
                    : "circle")
                    .foregroundStyle(batch.selectedIDs.contains(message.id)
                        ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .onTapGesture { batch.toggle(message.id) }
                    .accessibilityLabel(batch.selectedIDs.contains(message.id)
                        ? "Снять выбор" : "Выбрать")

                MessageRowView(
                    message: message,
                    moveTargets: moveTargets,
                    onMove: { targetID in onMove?(message.id, targetID) }
                )
                .contentShape(Rectangle())
                .onTapGesture { batch.toggle(message.id) }
            }
        } else {
            MessageRowView(
                message: message,
                moveTargets: moveTargets,
                onMove: { targetID in onMove?(message.id, targetID) }
            )
        }
    }

    // MARK: - Prefetch logic

    /// Запускает load-more, когда пользователь приблизился к концу списка.
    private func triggerPrefetchIfNeeded(for message: Message) {
        let messages = viewModel.messages
        guard !messages.isEmpty else { return }
        let threshold = max(0, messages.count - prefetchThreshold)
        if let idx = messages.firstIndex(where: { $0.id == message.id }), idx >= threshold {
            viewModel.loadMoreIfNeeded()
        }
    }
}
