# Модуль: Storage

<!-- Статус: план модуля. Код ещё не написан. -->

## Назначение

Локальное хранилище **только метаданных**. Обеспечивает мгновенный UI без сети, но никогда не хранит тел писем.

## Ключевые сущности

- `MetadataStore` — главный фасад (акtor).
- `AccountsTable` — id, тип, email, displayName, keychainRef. Без паролей.
- `MailboxesTable` — accountId, path, role, uidValidity, counters.
- `MessagesTable` — accountId, mailboxId, uid, messageId, from, to, subject, date, flags, size, hasAttachments, importance, threadId.
- `ThreadsTable` — группировка по References/Subject.

## Технологии

- **GRDB vs raw SQLite**: решаем на старте реализации. Предварительно склоняемся к **GRDB** — типобезопасные миграции, observables, `async/await`. Если зависимость окажется лишней — свернём на чистый SQLite через `SQLite3`-C-API.
- Файл БД: `~/Library/Application Support/MailAi/<accountId>.sqlite`. По одному файлу на аккаунт (изоляция окон-аккаунтов).
- Миграции: версионируются, обратная совместимость в пределах minor.

## Бизнес-логика

- Upsert писем по `(accountId, mailboxId, uid)`.
- Инвалидация по `uidValidity` — если сервер сбросил, пересинхронизируем mailbox.
- Счётчики непрочитанных/важных — материализованные через индексы, не пересчитываем на каждый запрос.
- Очистка: закрытое окно не выгружает БД сразу, но освобождает in-memory кеши.

## API

```swift
public actor MetadataStore: MetadataStoreProtocol {
    public func upsert(messages: [Message]) async throws
    public func messages(in: Mailbox.ID, filter: MessageFilter, page: Page) async throws -> [Message]
    public func delete(ids: [Message.ID]) async throws
    public func observe(mailbox: Mailbox.ID) -> AsyncStream<MessageSnapshot>
}
```

## Зависимости

- **От**: `Core`, GRDB (TBD).
- **Кто зависит**: `AppShell`, `Search`, `StatusBar`.

## Запрещено

- Писать `MessageBody` или любые тексты/HTML писем.
- Хранить секреты (пароли, токены) в БД.
