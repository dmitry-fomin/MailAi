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

## Pool-3 — IDLE-цикл активной папки

`IMAPIdleController` (actor) — отдельное соединение под `IDLE` (RFC 2177),
не пересекающееся с командным каналом `IMAPSession`. Жизненный цикл:

1. `start()` — connect + LOGIN, переход в `.connecting → .idle/.notSelected`.
2. `setMailbox(_:)` — `SELECT` + `IDLE`, выдача `IMAPIdleEvent` (EXISTS/EXPUNGE)
   через `events: AsyncStream<IMAPIdleEvent>`.
3. `withTaskGroup`-гонка трёх веток в `backgroundTask`: input команд из
   `IdleCommandQueue`, push-уведомления сервера, таймер 29 минут (RFC 2177
   рекомендует ре-IDLE до 29 мин). По таймауту — `DONE` + `IDLE` на той же
   папке, без переключения.
4. `stop()` / `Task.cancel()` — `DONE` + `LOGOUT` + close.

Реконнекта внутри нет: при обрыве — `.stopped(error)`, верхний уровень
пересоздаёт контроллер (граница «жив/мёртв»). После EXISTS-пуша потребитель
сам вызывает `headers(refresh: true)` — контроллер не знает о метаданных.

**Известный дефект** (issue Pool-3-fix): `stop()` может зависнуть на
полностью простаивающем канале, потому что `NIOAsyncChannel.inboundStream`
итератор не реагирует на `Task.cancel()` без серверного фрейма.
Прод-обходной путь — закрытие endpoint снаружи (см. `SessionPoolIDLESmoke`
кейс «обрыв канала»).

## Pool-4 — `SessionPoolIDLESmoke`

Executable-таргет (`Scripts/smoke.sh`), без XCTest. Поднимает fake IMAP-сервер
на NIO и проверяет:

- После `SELECT` + `IDLE` push-уведомление `* N EXISTS` доезжает до
  `IMAPIdleController.events` без ручного refresh.
- Cancel-инвариант: при принудительном закрытии канала контроллер переходит
  в `.stopped` без deadlock (purpose-built проверка для регрессии Pool-3-fix).

## SMTP-3 — `SendProvider`

- **Протокол `SendProvider` в `Core`**: `func send(envelope: Envelope, body: MIMEBody) async throws`.
- **`LiveSendProvider` (actor) в `MailTransport`**: открывает SMTP-сессию через
  `SMTPConnection.withOpen` на каждый вызов, шлёт `MAIL FROM/RCPT TO/DATA`,
  затем `QUIT`. Тело (`MIMEBody.raw`) живёт только в стеке вызова.
- **Endpoint**: берётся из `Account.smtpHost/smtpPort/smtpSecurity`. Если
  любое поле пустое — `MailError.unsupported` (отправка запрещена). Маппинг
  `Account.Security → SMTPEndpoint.Security`: `tls`/`startTLS`/`none → plain`.
- **Пароль**: сначала `SecretsStore.smtpPassword(forAccount:)`; если пуст —
  fallback на `password(forAccount:)` (IMAP-пароль). Решение принимает
  именно provider, не store. См. [Secrets.md](Secrets.md).

## SMTP-5 — Compose-интеграция

`AccountDataProviderFactory` (в AppShell) предоставляет:

- `makeSendProvider(for:secrets:) -> any SendProvider` — возвращает
  `LiveSendProvider` для live-режима, моки для mock-режима.
- `makeDraftSaver(for:secrets:) -> (DraftEnvelope, String) async throws -> Void` —
  замыкание поверх `LiveAccountDataProvider.saveDraft`.

Эти фабрики используются `ComposeViewModel`. UI-сцена — `ComposeScene`
(см. [AppShell.md](AppShell.md)).

## SMTP-6 — `SMTPEndToEndSmoke`

Executable-таргет, два fake-сервера на NIO в одном процессе:
`FakeSMTPServer` + `FakeIMAPServer`. Покрывает:

- happy path: `MAIL/RCPT/DATA` принимаются, затем `APPEND` черновика в Drafts;
- ошибка `RCPT 550` от SMTP — `LiveSendProvider` возвращает ошибку, `APPEND`
  не вызывается;
- ошибка `APPEND` от IMAP — `saveDraft` бросает, текст письма не остаётся
  в памяти после возврата (проверяется через scope-инвариант).

Smoke не использует XCTest — гейтится `Scripts/smoke.sh`.
