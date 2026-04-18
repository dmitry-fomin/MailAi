import Foundation
import Core
import Storage

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

    public init(account: Account, store: any MetadataStore = InMemoryMetadataStore()) {
        self.account = account
        self.store = store
    }

    // MARK: - AccountDataProvider (заглушки до C4)

    public func mailboxes() async throws -> [Mailbox] {
        throw MailError.unsupported("LiveAccountDataProvider.mailboxes — подключение собирается в C4")
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
