import Foundation

/// Лёгкий публичный API поиска. Полноценный SearchCoordinator (server-side
/// fallback, stream) появится позже; пока хватает простого async-вызова.
public protocol SearchService: Sendable {
    /// Выполняет поиск в контексте аккаунта.
    /// `rawQuery` — сырая строка от пользователя: парсит реализация.
    /// `mailboxID` (опц.) — ограничивает выборку одной папкой.
    func search(
        rawQuery: String,
        accountID: Account.ID,
        mailboxID: Mailbox.ID?,
        limit: Int
    ) async throws -> [Message]
}

/// Серверный поиск через IMAP SEARCH (или Graph search для Exchange).
/// Реализуется транспортным слоем; вызывается `SearchCoordinator`'ом
/// как fallback, когда локальный FTS5 не даёт результатов.
public protocol ServerSearchProvider: Actor {
    func serverSearch(
        query: String,
        mailboxID: Mailbox.ID?,
        accountID: Account.ID,
        limit: Int
    ) async throws -> [Message]
}
