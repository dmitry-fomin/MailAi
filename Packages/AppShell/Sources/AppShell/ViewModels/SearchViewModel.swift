import Foundation
import Combine
import Core
import UI

/// ViewModel поискового UI. Управляет строкой запроса, фильтрами, историей
/// и делегирует выполнение поиска в `AccountSessionModel`.
///
/// Изолирован на `@MainActor`, поскольку публикует изменения для SwiftUI.
@MainActor
public final class SearchViewModel: ObservableObject {

    // MARK: - Published state

    /// Строка поиска, которую вводит пользователь.
    @Published public var rawQuery: String = ""

    /// Выбранный фильтр области поиска.
    @Published public var scope: SearchScope = .all

    /// Результаты поиска (метаданные писем).
    @Published public private(set) var results: [Message] = []

    /// `true` — выполняется поисковый запрос.
    @Published public private(set) var isSearching: Bool = false

    /// `true` — строка поиска активна (SearchBar раскрыта).
    @Published public var isActive: Bool = false

    /// Последние N запросов пользователя (history).
    @Published public private(set) var recentQueries: [String] = []

    // MARK: - Dependencies

    private weak var session: AccountSessionModel?
    private var cancellables: Set<AnyCancellable> = []
    private var searchTask: Task<Void, Never>?

    // MARK: - Configuration

    private let maxHistoryCount = 10
    /// Debounce перед отправкой запроса (мс).
    private let debounceMilliseconds: Int = 200

    // MARK: - Init

    public init(session: AccountSessionModel) {
        self.session = session
        bindQuery()
        loadHistory()
    }

    // MARK: - Public API

    /// Сбрасывает поиск и скрывает SearchBar.
    public func clear() {
        rawQuery = ""
        results = []
        isActive = false
        session?.searchQuery = ""
    }

    /// Активирует поиск (Cmd+F).
    public func activate() {
        isActive = true
    }

    /// Сохраняет текущий запрос в историю и выполняет поиск немедленно.
    public func commitQuery() {
        let q = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        addToHistory(q)
        executeSearch(query: buildQuery())
    }

    /// Применяет выбранный исторический запрос.
    public func applyHistoryQuery(_ query: String) {
        rawQuery = applyScope(to: query)
        commitQuery()
    }

    // MARK: - Private

    /// Подписываемся на изменения строки с debounce.
    private func bindQuery() {
        $rawQuery
            .debounce(for: .milliseconds(debounceMilliseconds), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.onQueryChanged()
            }
            .store(in: &cancellables)
    }

    private func onQueryChanged() {
        let q = rawQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            results = []
            isSearching = false
            session?.searchQuery = ""
            return
        }
        executeSearch(query: buildQuery())
    }

    /// Формирует финальную строку запроса с учётом выбранного scope.
    private func buildQuery() -> String {
        let q = rawQuery.trimmingCharacters(in: .whitespaces)
        return applyScope(to: q)
    }

    private func applyScope(to query: String) -> String {
        switch scope {
        case .all:
            return query
        case .from:
            // Если пользователь ещё не добавил from: — добавляем.
            if query.hasPrefix("from:") { return query }
            return "from:\(query)"
        case .subject:
            // Простой поиск по теме — передаём как свободный текст.
            // LocalSearcher ищет по subject через FTS5.
            return query
        }
    }

    private func executeSearch(query: String) {
        searchTask?.cancel()
        guard let session else { return }

        isSearching = true
        session.searchQuery = query

        searchTask = Task {
            // Небольшой таймаут, чтобы убедиться, что сессия завершила задачу.
            // AccountSessionModel.performSearch() вызывается через didSet.
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            self.results = session.searchResults
            self.isSearching = session.isSearching
        }
    }

    // MARK: - History

    private let historyKey = "SearchViewModel.recentQueries"

    private func loadHistory() {
        recentQueries = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private func addToHistory(_ query: String) {
        var history = recentQueries.filter { $0 != query }
        history.insert(query, at: 0)
        recentQueries = Array(history.prefix(maxHistoryCount))
        UserDefaults.standard.set(recentQueries, forKey: historyKey)
    }

    /// Очищает историю поиска.
    public func clearHistory() {
        recentQueries = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
}
