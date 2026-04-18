import Foundation
import Core

/// Реальный провайдер данных: IMAP (SwiftNIO) + `MetadataStore`.
/// Заглушка — наполнение в фазе B (см. IMPLEMENTATION_PLAN.md).
public struct LiveAccountDataProvider: AccountDataProvider {
    public let account: Account

    public init(account: Account) {
        self.account = account
    }

    public func mailboxes() async throws -> [Mailbox] {
        throw MailError.unsupported("LiveAccountDataProvider.mailboxes — TODO фаза B")
    }

    public func messages(in mailbox: Mailbox.ID, page: Page) -> AsyncThrowingStream<[Message], any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MailError.unsupported("messages — TODO фаза B"))
        }
    }

    public func body(for message: Message.ID) -> AsyncThrowingStream<ByteChunk, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MailError.unsupported("body — TODO фаза B"))
        }
    }

    public func threads(in mailbox: Mailbox.ID) async throws -> [MessageThread] {
        throw MailError.unsupported("threads — TODO фаза B")
    }
}
