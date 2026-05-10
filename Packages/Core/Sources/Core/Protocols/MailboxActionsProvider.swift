import Foundation

/// Опциональный companion к `AccountDataProvider`: операции управления
/// папками на IMAP-сервере (CREATE, RENAME, DELETE).
///
/// `LiveAccountDataProvider` реализует методы через `IMAPSession`.
/// Моки могут не реализовывать — SidebarView проверяет наличие через
/// `provider as? any MailboxActionsProvider`.
@preconcurrency
public protocol MailboxActionsProvider: Sendable {
    /// Создаёт новую папку с указанным именем внутри родительской папки.
    ///
    /// - Parameters:
    ///   - name: Имя новой папки (без пути).
    ///   - parentPath: Путь родительской папки (IMAP path). `nil` — корень.
    /// - Returns: Созданная папка.
    func createMailbox(name: String, parentPath: String?) async throws -> Mailbox

    /// Переименовывает существующую папку.
    ///
    /// - Parameters:
    ///   - mailboxID: Идентификатор переименовываемой папки.
    ///   - newName: Новое имя (без пути).
    func renameMailbox(mailboxID: Mailbox.ID, newName: String) async throws

    /// Удаляет папку и весь её контент.
    ///
    /// - Important: Системные папки (Inbox, Sent, Trash и т.д.) удалять запрещено —
    ///   реализация должна бросить `MailError.unsupported` при попытке.
    func deleteMailbox(mailboxID: Mailbox.ID) async throws
}
