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

## B7 — Streaming body + MIME

Фаза B7 добавила потоковое чтение тела письма и стриминговый MIME-парсер. Всё
реализовано внутри `IMAPConnection`, без новых зависимостей.

### `IMAPConnection.streamBody(uid:section:)`

```swift
let stream = connection.streamBody(uid: 4321)  // BODY.PEEK[] по умолчанию
for try await chunk in stream {
    // chunk: ByteChunk { let bytes: [UInt8] } (из Core)
    parser.feed(chunk.bytes)
}
```

- Отправляет `UID FETCH <uid> BODY.PEEK[<section>]` (`PEEK` — не устанавливает
  `\Seen`). Пометку «прочитано» делаем отдельно по явному действию пользователя.
- Из IMAP-литерала `{N}` читает ровно `N` байт и отдаёт их чанками по мере
  прихода строк из NIO-канала. Полное тело в памяти **не аккумулируется** —
  это соответствует правилу MailAi «тела писем не кешируем».
- Ошибки: `IMAPBodyStreamError.missingLiteralLength`, `.truncatedLiteral`,
  `.serverError(status:text:)`; канал/IO — пробрасываются как-есть.

### Стриминговый MIME-парсер (`MIMEStreamParser`)

Событийный: получает сырые байты тела, выдаёт `MIMEStreamEvent`:

- `.partStart(path: [Int], headers: [MIMEHeader])` — заголовки части;
- `.bodyChunk(path: [Int], bytes: [UInt8])` — декодированные байты текущей части;
- `.partEnd(path: [Int])` — конец части.

`path` — индексы вложенности (пустой для корня, `[0]` — первая дочерняя часть и т. д.).
Поддерживает `multipart/*` с boundary, вложенные multipart'ы, `quoted-printable`,
`base64`, `7bit/8bit/binary`. Тело части декодируется потоково (`MIMEStreamingDecoder`).

### Декодирование текста

- `MIMECharset.decode(_:charset:)` — применяет charset из `Content-Type` с
  UTF-8 fallback при неизвестной кодировке или ошибке.
- `IMAPHeaderDecoder.decode(_:)` — RFC 2047 encoded-words (Q/B, любой
  IANA-charset через `CFStringConvertIANACharSetNameToEncoding`).
- `MIMEHeaderUnfold.unfold(_:)` — RFC 5322 header unfolding (CRLF перед WSP
  удаляется, WSP сохраняется). `MIMEHeaderUnfold.parse(_:)` возвращает
  пары `(name, value)` с уже раскодированными RFC 2047-словами.

### Инварианты B7

- `streamBody` держит в памяти максимум одну IMAP-линию (килобайты), не всё тело.
- MIME-парсер аккумулирует только текущую незавершённую линию + header-буфер
  текущей части; между частями буфер обнуляется.
- Ничего не логируется: ни заголовки, ни тела, ни адреса.
- Вложения (`base64` с большим размером) предполагают пользовательский сценарий
  «сохранить как файл» — см. `docs/Attachments.md`. В рамках B7 — только стрим
  байтов, без записи на диск.

## SMTP-4 — Черновики через IMAP APPEND

### `IMAPConnection.append(mailbox:flags:date:literal:)`

RFC 3501 §6.3.11. Двухфазная команда:

1. `<tag> APPEND <mailbox> [(flags)] [date-time] {N}` — клиент передаёт длину
   литерала в октетах UTF-8.
2. Сервер отвечает `+ ...` continuation.
3. Клиент шлёт литерал длиной ровно `N` байт + завершающий `\r\n`.
4. Сервер возвращает финальный tagged-ответ.

Помощник `IMAPConnection.formatAppendCommand(...)` строит первую строку
без CRLF — используется как для отправки, так и для тестов
(`IMAPAppendSmoke`).

### `LiveAccountDataProvider.saveDraft(envelope:body:)`

Находит папку с `Mailbox.Role == .drafts` через `mailboxes()`, компонует
MIME через `MIMEComposer`, APPEND'ит с флагом `\Draft`.

Тело письма живёт в памяти только на время вызова — после `saveDraft`
строка `composed` выходит из скоупа, ни в кеше, ни в БД, ни в логах
не сохраняется. Черновики хранятся **только** на сервере IMAP.
