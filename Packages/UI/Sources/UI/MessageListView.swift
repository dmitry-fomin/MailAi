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

// MARK: - MessageListView

/// Список писем с виртуализацией через `List` и пагинацией (load-more
/// при скролле к концу).
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

    public init(
        viewModel: MessageListViewModel,
        selection: Binding<Message.ID?>,
        prefetchThreshold: Int = 10,
        moveTargets: [Mailbox] = [],
        onMove: ((Message.ID, Mailbox.ID) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self._selection = selection
        self.prefetchThreshold = prefetchThreshold
        self.moveTargets = moveTargets
        self.onMove = onMove
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(viewModel.messages) { message in
                MessageRowView(
                    message: message,
                    moveTargets: moveTargets,
                    onMove: { targetID in onMove?(message.id, targetID) }
                )
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
