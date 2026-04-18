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
