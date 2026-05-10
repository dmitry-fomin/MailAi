import SwiftUI
import Core

/// Список результатов поиска с подсветкой совпадений.
///
/// Показывается вместо обычного `MessageListView` когда активен поиск.
/// Каждая строка использует `SearchResultRowView` с выделением терминов запроса.
///
/// ## Использование
/// ```swift
/// SearchResultsView(
///     results: searchVM.results,
///     query: searchVM.rawQuery,
///     isSearching: searchVM.isSearching,
///     selectedID: $session.selectedMessageID,
///     recentQueries: searchVM.recentQueries,
///     onSelectQuery: { searchVM.applyHistoryQuery($0) },
///     onClearHistory: { searchVM.clearHistory() }
/// )
/// ```
public struct SearchResultsView: View {

    // MARK: - Data

    public let results: [Message]
    public let query: String
    public let isSearching: Bool

    // MARK: - Bindings

    @Binding public var selectedID: Message.ID?

    // MARK: - History

    public let recentQueries: [String]
    public var onSelectQuery: (String) -> Void
    public var onClearHistory: () -> Void

    // MARK: - Init

    public init(
        results: [Message],
        query: String,
        isSearching: Bool,
        selectedID: Binding<Message.ID?>,
        recentQueries: [String] = [],
        onSelectQuery: @escaping (String) -> Void = { _ in },
        onClearHistory: @escaping () -> Void = {}
    ) {
        self.results = results
        self.query = query
        self.isSearching = isSearching
        _selectedID = selectedID
        self.recentQueries = recentQueries
        self.onSelectQuery = onSelectQuery
        self.onClearHistory = onClearHistory
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if isSearching {
                loadingView
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                historyView
            } else if results.isEmpty {
                emptyResultsView
            } else {
                resultsList
            }
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Поиск…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyResultsView: some View {
        ContentUnavailableView.search(text: query)
    }

    private var resultsList: some View {
        List(results, id: \.id, selection: $selectedID) { message in
            SearchResultRowView(message: message, query: query)
                .tag(message.id)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var historyView: some View {
        if recentQueries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Введите запрос для поиска")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(recentQueries, id: \.self) { q in
                        Button {
                            onSelectQuery(q)
                        } label: {
                            Label(q, systemImage: "clock.arrow.circlepath")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Недавние запросы")
                        Spacer()
                        Button("Очистить", action: onClearHistory)
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - SearchResultRowView

/// Строка результата поиска с подсветкой совпадений.
public struct SearchResultRowView: View {

    public let message: Message
    public let query: String

    public init(message: Message, query: String) {
        self.message = message
        self.query = query
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Строка: отправитель + дата
            HStack {
                Text(senderName)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Тема с подсветкой
            highlightedText(message.subject, terms: searchTerms)
                .font(.subheadline)
                .lineLimit(1)

            // Preview с подсветкой
            if let preview = message.preview, !preview.isEmpty {
                highlightedText(preview, terms: searchTerms)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var senderName: String {
        message.from?.name ?? message.from?.address ?? "Неизвестный отправитель"
    }

    private var formattedDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(message.date) {
            return message.date.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(message.date) {
            return "Вчера"
        } else {
            return message.date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// Слова из поискового запроса (без операторов from:, is:, etc).
    private var searchTerms: [String] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.contains(":") }
            .filter { !$0.isEmpty }
    }

    /// Строит `Text` с подсветкой найденных слов через `.mark` background.
    @ViewBuilder
    private func highlightedText(_ source: String, terms: [String]) -> some View {
        if terms.isEmpty {
            Text(source)
        } else {
            Text(highlight(source, terms: terms))
        }
    }

    /// Разбивает строку по вхождениям термов и строит AttributedString с жёлтым фоном.
    private func highlight(_ source: String, terms: [String]) -> AttributedString {
        var attributed = AttributedString(source)
        let lower = source.lowercased()

        for term in terms {
            let termLower = term.lowercased()
            var searchStart = lower.startIndex
            while searchStart < lower.endIndex,
                  let range = lower.range(of: termLower, range: searchStart..<lower.endIndex) {
                // Конвертируем String.Index в AttributedString.Index.
                let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
                let attrEnd   = AttributedString.Index(range.upperBound, within: attributed)
                if let attrStart, let attrEnd {
                    attributed[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
                    attributed[attrStart..<attrEnd].foregroundColor = .primary
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}
