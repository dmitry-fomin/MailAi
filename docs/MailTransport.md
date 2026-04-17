# Модуль: MailTransport

<!-- Статус: план модуля. Код ещё не написан. -->

## Назначение

Унифицированный доступ к почтовым серверам. Скрывает различия между IMAP и Exchange за одним протоколом. Отвечает за получение списков писем, чтение тел (стримом), удаление, отправку.

## Ключевые сущности

- `IMAPTransport` — реализация через IMAP4rev1. Библиотека — TBD (`MailCore2` через Obj-C интероп, либо собственная на `Network.framework`; решим в шаге «библиотеки»).
- `ExchangeTransport` — реализация через EWS или Microsoft Graph (решим по ходу; предпочтительно Graph — современнее, OAuth).
- `MailTransportFactory` — создаёт транспорт по типу аккаунта.
- `MessageStream` — `AsyncThrowingStream<Data, Error>` для тел писем (чтобы не держать всё в памяти).

## Бизнес-логика

- **Список писем**: пагинация по UID, загружаются только метаданные. Полные тела — только по явному запросу.
- **Удаление**: массовое через batch-операции сервера (IMAP: `UID STORE +FLAGS \Deleted` + `EXPUNGE`; Exchange: batch Graph request). Подтверждение на уровне UI.
- **Отправка**: SMTP для IMAP-аккаунтов, Graph `sendMail` для Exchange.
- **Тела писем**: возвращаются стримом, парсятся по чанкам. После закрытия view тело освобождается из памяти.
- **Переподключение**: с экспоненциальным backoff, без потери очереди операций.

## API (публичный)

```swift
public protocol MailTransport: Sendable {
    func listMailboxes() async throws -> [Mailbox]
    func fetchHeaders(in: Mailbox, range: UIDRange) async throws -> [Message]
    func fetchBody(messageId: Message.ID) -> AsyncThrowingStream<ByteChunk, Error>
    func delete(messageIds: [Message.ID]) async throws
    func send(draft: OutgoingMessage) async throws
}
```

## Зависимости

- **От**: `Core`, `Secrets` (для авторизации).
- **Кто зависит**: `AppShell`, `Search`, `AI` (через AppShell, не напрямую).
