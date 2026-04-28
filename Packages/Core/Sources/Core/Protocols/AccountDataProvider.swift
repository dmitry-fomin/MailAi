import Foundation

/// Страница для пагинации по списку писем.
public struct Page: Sendable, Hashable {
    public let offset: Int
    public let limit: Int
    public init(offset: Int, limit: Int) {
        self.offset = offset
        self.limit = limit
    }
}

/// Ключевая абстракция: UI никогда не знает, откуда пришли данные —
/// из `MockAccountDataProvider` или из `LiveAccountDataProvider`
/// (MailTransport + MetadataStore).
///
/// Все методы `Sendable`-безопасны и возвращают значения; стримы закрываются,
/// когда подписчик отменяет задачу.
@preconcurrency
public protocol AccountDataProvider: Sendable {
    /// Аккаунт, который обслуживает провайдер.
    var account: Account { get }

    /// Дерево папок аккаунта.
    func mailboxes() async throws -> [Mailbox]

    /// Страницы метаданных писем в папке. Стрим завершается, когда страница
    /// отправлена (или генерирует новую при refresh — зависит от реализации).
    func messages(in mailbox: Mailbox.ID, page: Page) -> AsyncThrowingStream<[Message], any Error>

    /// Стрим тела письма по чанкам. Реализация обязана не кешировать полное
    /// тело в персистентном хранилище.
    func body(for message: Message.ID) -> AsyncThrowingStream<ByteChunk, any Error>

    /// Треды по конкретному mailbox'у.
    func threads(in mailbox: Mailbox.ID) async throws -> [MessageThread]
}
