import Foundation
import GRDB
import Core

/// Реализация `SearchService` на GRDB/FTS5. Используется AccountSessionModel
/// поверх того же DatabasePool, что обслуживает `GRDBMetadataStore`.
public struct GRDBSearchService: SearchService {
    private let searcher: LocalSearcher

    public init(pool: DatabasePool) {
        self.searcher = LocalSearcher(pool: pool)
    }

    public func search(
        rawQuery: String,
        accountID: Account.ID,
        mailboxID: Mailbox.ID?,
        limit: Int
    ) async throws -> [Message] {
        let query = SearchQueryParser.parse(rawQuery)
        guard !query.isEmpty else { return [] }
        return try await searcher.search(
            query: query,
            accountID: accountID,
            mailboxID: mailboxID,
            limit: limit
        )
    }
}
