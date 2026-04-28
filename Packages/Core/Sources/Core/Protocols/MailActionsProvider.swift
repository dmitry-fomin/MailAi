import Foundation

/// Опциональный companion к `AccountDataProvider`: операции, меняющие
/// состояние на сервере (удаление, перемещение, флажки, прочитано).
/// `LiveAccountDataProvider` реализует; моки могут не реализовывать — тогда
/// UI-кнопки остаются видимыми, но ничего не делают (ReaderToolbar решает
/// это сам, проверяя `provider as? any MailActionsProvider`).
@preconcurrency
public protocol MailActionsProvider: Sendable {
    func delete(messageID: Message.ID) async throws
    func archive(messageID: Message.ID) async throws
    func setRead(_ read: Bool, messageID: Message.ID) async throws
    func setFlagged(_ flagged: Bool, messageID: Message.ID) async throws
    func moveToMailbox(messageID: Message.ID, targetMailboxID: Mailbox.ID) async throws

    /// Восстанавливает письма из Trash в указанную папку (по умолчанию — Inbox).
    /// MailAi-9fi0: Trash restore.
    func restore(messageIDs: [Message.ID], to targetMailboxID: Mailbox.ID) async throws
}
