import Core

/// Координатор поиска: сначала пробует локальный FTS5, при нулевом результате
/// передаёт запрос серверному провайдеру (IMAP SEARCH / Graph).
///
/// Соответствует `SearchService` — прозрачно подставляется вместо
/// `GRDBSearchService` в `AccountSessionModel.searchService`.
public actor SearchCoordinator: SearchService {
    private let local: any SearchService
    private let remote: (any ServerSearchProvider)?

    public init(local: any SearchService, remote: (any ServerSearchProvider)? = nil) {
        self.local = local
        self.remote = remote
    }

    public func search(
        rawQuery: String,
        accountID: Account.ID,
        mailboxID: Mailbox.ID?,
        limit: Int
    ) async throws -> [Message] {
        let localResults = try await local.search(
            rawQuery: rawQuery,
            accountID: accountID,
            mailboxID: mailboxID,
            limit: limit
        )
        // Локальные результаты есть — возвращаем без запроса к серверу.
        if !localResults.isEmpty || remote == nil {
            return localResults
        }
        // Fallback: серверный поиск.
        return try await remote!.serverSearch(
            query: rawQuery,
            mailboxID: mailboxID,
            accountID: accountID,
            limit: limit
        )
    }
}
