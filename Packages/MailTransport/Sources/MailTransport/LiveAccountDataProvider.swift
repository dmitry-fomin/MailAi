import Foundation
import Core
import Storage
import Secrets

/// Реальный провайдер данных: IMAP (SwiftNIO) + `MetadataStore`.
///
/// На фазе B6 наполнен `syncHeaders(...)` — он берёт готовое
/// `IMAPConnection`, выполняет `UID FETCH` и батч-upsert в store.
/// Полноценный `messages(in:page:)` со своим пулом соединений и авторизацией
/// будет собран вместе с C4 (онбординг) — тогда провайдер начнёт сам
/// открывать соединения по `Keychain`-секретам.
public final class LiveAccountDataProvider: AccountDataProvider, @unchecked Sendable {
    public let account: Account
    public let store: any MetadataStore
    public let secrets: (any SecretsStore)?
    public let endpoint: IMAPEndpoint

    public init(
        account: Account,
        store: any MetadataStore = InMemoryMetadataStore(),
        secrets: (any SecretsStore)? = nil,
        endpoint: IMAPEndpoint? = nil
    ) {
        self.account = account
        self.store = store
        self.secrets = secrets
        self.endpoint = endpoint ?? IMAPEndpoint(
            host: account.host,
            port: Int(account.port),
            security: account.security == .none ? .plain : .tls
        )
    }

    /// Открывает временную IMAP-сессию (LOGIN → body → LOGOUT). Пароль берётся
    /// из `SecretsStore`. Закрывается автоматически по выходу из замыкания.
    /// Используется каждой публичной операцией провайдера до появления
    /// session-scoped connection actor'а.
    func withSession<Result: Sendable>(
        _ body: @Sendable (IMAPConnection) async throws -> Result
    ) async throws -> Result {
        guard let secrets else {
            throw MailError.unsupported("LiveAccountDataProvider сконструирован без SecretsStore — нельзя выполнить live-операцию.")
        }
        guard let password = try await secrets.password(forAccount: account.id) else {
            throw MailError.keychain(.unknown)
        }
        return try await IMAPConnection.withOpen(endpoint: endpoint) { conn in
            try await conn.login(username: account.username, password: password)
            let result = try await body(conn)
            try await conn.logout()
            return result
        }
    }

    // MARK: - AccountDataProvider

    public func mailboxes() async throws -> [Mailbox] {
        let entries = try await withSession { conn in
            try await conn.list()
        }
        let accountID = account.id
        let mailboxes = entries.map { entry -> Mailbox in
            let role = Self.mapRole(flags: entry.flags, path: entry.path)
            return Mailbox(
                id: Mailbox.ID(entry.path),
                accountID: accountID,
                name: Self.displayName(for: entry.path, role: role),
                path: entry.path,
                role: role,
                unreadCount: 0,
                totalCount: 0,
                uidValidity: nil
            )
        }
        // Персистентный список папок живёт в store вместе с MetadataStore
        // (Live-3): offline-режим пока не нужен — UI перестраивает sidebar
        // при каждом открытии окна.
        return mailboxes
    }

    /// Маппит RFC 6154 SPECIAL-USE flags и имя папки на `Mailbox.Role`.
    /// Порядок проверки важен: сначала точные SPECIAL-USE, потом хёрестика
    /// по имени — разные сервера шлют флаги по-разному.
    static func mapRole(flags: [String], path: String) -> Mailbox.Role {
        let normalizedFlags = Set(flags.map { $0.lowercased() })
        if normalizedFlags.contains("\\inbox") { return .inbox }
        if normalizedFlags.contains("\\sent") { return .sent }
        if normalizedFlags.contains("\\drafts") { return .drafts }
        if normalizedFlags.contains("\\trash") { return .trash }
        if normalizedFlags.contains("\\junk") { return .spam }
        if normalizedFlags.contains("\\archive") || normalizedFlags.contains("\\all") { return .archive }
        if normalizedFlags.contains("\\flagged") { return .flagged }
        // Fallback по имени (основные раскладки большинства IMAP-серверов).
        let upper = path.uppercased()
        let tail = upper.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? upper
        switch tail {
        case "INBOX":                       return .inbox
        case "SENT", "SENT ITEMS", "SENT MESSAGES", "ОТПРАВЛЕННЫЕ", "ISPOLZOVANO":
            return .sent
        case "DRAFTS", "ЧЕРНОВИКИ":         return .drafts
        case "TRASH", "DELETED", "DELETED ITEMS", "КОРЗИНА", "УДАЛЁННЫЕ":
            return .trash
        case "SPAM", "JUNK", "JUNK E-MAIL", "СПАМ":
            return .spam
        case "ARCHIVE", "ALL MAIL", "АРХИВ", "ВСЯ ПОЧТА":
            return .archive
        default:                            return .custom
        }
    }

    /// Человекочитаемое имя папки: последний сегмент иерархии. Для INBOX
    /// возвращаем «Входящие», остальные системные — тоже локализуем.
    static func displayName(for path: String, role: Mailbox.Role) -> String {
        switch role {
        case .inbox:   return "Входящие"
        case .sent:    return "Отправленные"
        case .drafts:  return "Черновики"
        case .trash:   return "Корзина"
        case .spam:    return "Спам"
        case .archive: return "Архив"
        case .flagged: return "С флажком"
        case .custom:
            let segments = path.split(whereSeparator: { $0 == "/" || $0 == "." })
            return segments.last.map(String.init) ?? path
        }
    }

    public func messages(in mailbox: Mailbox.ID, page: Page) -> AsyncThrowingStream<[Message], any Error> {
        // До C4 отдаём то, что уже лежит в store — этого достаточно, чтобы
        // UI рендерил метаданные после внешней синхронизации (см. B9 CLI).
        let store = self.store
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let messages = try await store.messages(in: mailbox, page: page)
                    continuation.yield(messages)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func body(for message: Message.ID) -> AsyncThrowingStream<ByteChunk, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MailError.unsupported("body — TODO фаза B7"))
        }
    }

    public func threads(in mailbox: Mailbox.ID) async throws -> [MessageThread] {
        throw MailError.unsupported("threads — TODO фаза B")
    }

    // MARK: - B6: синхронизация заголовков

    /// Результат батчевой синхронизации заголовков для диапазона UID.
    public struct SyncHeadersResult: Sendable, Equatable {
        public let fetched: Int
        public let upserted: Int
        public let parseErrors: Int
        public let skippedWithoutUID: Int
    }

    /// Выполняет `UID FETCH` по указанному диапазону, маппит каждый ответ в
    /// `Message` и батчем upsert-ит в `store`. Batch-границы делает сам GRDB
    /// (единый `upsert(_:)`-вызов), поэтому пишем одной транзакцией.
    ///
    /// IMAP-сессия (`connection`) передаётся снаружи: провайдер не держит
    /// соединений до C4. Вызывающий гарантирует, что соединение уже
    /// авторизовано и папка `SELECT`-нута.
    public func syncHeaders(
        mailbox: Mailbox.ID,
        uidRange: IMAPUIDRange,
        using connection: IMAPConnection
    ) async throws -> SyncHeadersResult {
        let (fetches, parseErrors) = try await connection.uidFetchHeaders(range: uidRange)
        var mapped: [Message] = []
        mapped.reserveCapacity(fetches.count)
        var skipped = 0
        for fetch in fetches {
            if let msg = IMAPFetchMapper.toMessage(fetch, accountID: account.id, mailboxID: mailbox) {
                mapped.append(msg)
            } else {
                skipped += 1
            }
        }
        if !mapped.isEmpty {
            try await store.upsert(mapped)
        }
        return SyncHeadersResult(
            fetched: fetches.count,
            upserted: mapped.count,
            parseErrors: parseErrors,
            skippedWithoutUID: skipped
        )
    }
}
