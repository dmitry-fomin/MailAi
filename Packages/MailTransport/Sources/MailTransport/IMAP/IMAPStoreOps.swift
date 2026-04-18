import Foundation

/// Операции изменения флагов и перемещения писем (IMAP UID STORE/COPY/MOVE/EXPUNGE).
/// Mail-1: используются ReaderToolbar-действиями через `LiveAccountDataProvider`.
extension IMAPConnection {

    public enum StoreOperation: Sendable, Equatable {
        /// `+FLAGS` — добавить флаги.
        case add
        /// `-FLAGS` — снять флаги.
        case remove
        /// `FLAGS` — заменить набор.
        case replace

        var token: String {
            switch self {
            case .add:     return "+FLAGS"
            case .remove:  return "-FLAGS"
            case .replace: return "FLAGS"
            }
        }
    }

    public enum StandardFlag: String, Sendable, CaseIterable {
        case seen     = "\\Seen"
        case flagged  = "\\Flagged"
        case deleted  = "\\Deleted"
        case answered = "\\Answered"
        case draft    = "\\Draft"
    }

    /// UID STORE — возвращает обновлённые FETCH-ответы, если сервер их пришлёт
    /// (по умолчанию .SILENT не добавляется, чтобы получить свежие флаги).
    @discardableResult
    public func uidStore(
        uid: UInt32,
        operation: StoreOperation,
        flags: [StandardFlag]
    ) async throws -> IMAPCommandResult {
        let flagList = flags.map(\.rawValue).joined(separator: " ")
        let cmd = "UID STORE \(uid) \(operation.token) (\(flagList))"
        let result = try await execute(cmd)
        try Self.assertOK(result.tagged)
        return result
    }

    /// UID COPY <uid> <destination-mailbox>. Возвращается OK при успехе;
    /// исходная копия остаётся на месте (для удаления нужен STORE+EXPUNGE или
    /// UID MOVE из RFC 6851).
    public func uidCopy(uid: UInt32, to destination: String) async throws {
        let cmd = "UID COPY \(uid) \(Self.quote(destination))"
        let result = try await execute(cmd)
        try Self.assertOK(result.tagged)
    }

    /// UID MOVE (RFC 6851). Если сервер не поддерживает — fallback на
    /// COPY + STORE +\Deleted + EXPUNGE. Клиент узнаёт про MOVE по CAPABILITY;
    /// этот метод предполагает, что вызывающий уже определился.
    public func uidMove(uid: UInt32, to destination: String) async throws {
        let cmd = "UID MOVE \(uid) \(Self.quote(destination))"
        let result = try await execute(cmd)
        try Self.assertOK(result.tagged)
    }

    /// Fallback-перемещение для серверов без MOVE-расширения.
    public func uidMoveFallback(uid: UInt32, to destination: String) async throws {
        try await uidCopy(uid: uid, to: destination)
        try await uidStore(uid: uid, operation: .add, flags: [.deleted])
        try await expunge()
    }

    /// EXPUNGE — физическое удаление писем с флагом \Deleted в текущей папке.
    public func expunge() async throws {
        let result = try await execute("EXPUNGE")
        try Self.assertOK(result.tagged)
    }

    // MARK: - Helpers

    private static func assertOK(_ tagged: IMAPTaggedResponse) throws {
        guard tagged.status == .ok else {
            throw IMAPConnectionError.commandFailed(
                status: tagged.status, text: tagged.text
            )
        }
    }
}
