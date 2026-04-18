# GRDB.swift

**Library ID (Context7)**: `/groue/grdb.swift` (v7.x)
**Роль в проекте**: локальное хранилище метаданных (модуль `Storage`).

## Назначение

Типобезопасная SQLite-обёртка: схема, миграции, query builder, observation, async/await.

## Подключение

```swift
// Package.swift
.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
// .product(name: "GRDB", package: "GRDB.swift")
```

## База: DatabaseQueue vs DatabasePool

- `DatabaseQueue` — одна сериализованная очередь, простой сценарий, меньше памяти.
- `DatabasePool` — один writer + множество readers (WAL). **Наш выбор** для `MetadataStore`: UI-читает, фоновый sync-пишет.

```swift
let dbURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "MailAi/\(accountId).sqlite")

var config = Configuration()
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL;")
    try db.execute(sql: "PRAGMA foreign_keys = ON;")
}
let dbPool = try DatabasePool(path: dbURL.path, configuration: config)
```

## Миграции

```swift
var migrator = DatabaseMigrator()

migrator.registerMigration("v1: core schema") { db in
    try db.create(table: "account") { t in
        t.primaryKey("id", .text)
        t.column("type", .text).notNull()
        t.column("email", .text).notNull()
        t.column("display_name", .text).notNull()
        t.column("keychain_ref", .text).notNull()
    }
    try db.create(table: "message") { t in
        t.primaryKey("id", .text)
        t.belongsTo("account", onDelete: .cascade).notNull()
        t.column("mailbox_id", .text).notNull().indexed()
        t.column("uid", .integer).notNull()
        t.column("message_id", .text).unique()
        t.column("from_addr", .text)
        t.column("subject", .text)
        t.column("date", .datetime).indexed()
        t.column("flags", .integer).notNull().defaults(to: 0)
        t.column("size", .integer).notNull().defaults(to: 0)
        t.column("has_attachments", .boolean).notNull().defaults(to: false)
        t.column("importance", .integer)
        t.column("thread_id", .text).indexed()
        t.column("summary_hash", .text)
    }
}

try await migrator.migrate(dbPool)
```

## FTS5 для Search

```swift
migrator.registerMigration("v2: fts5") { db in
    try db.create(virtualTable: "message_fts", using: FTS5()) { t in
        t.tokenizer = .unicode61()
        t.column("from_addr")
        t.column("subject")
        t.column("summary_text")
    }
    // заполняется триггерами из message + summary
}
```

## Batch upsert

```swift
try await dbPool.write { db in
    for chunk in messages.chunked(by: 500) {
        for msg in chunk {
            try msg.upsert(db)  // PersistableRecord с onConflict
        }
    }
}
```

## Observation → AsyncSequence

```swift
let observation = ValueObservation.tracking { db in
    try Message
        .filter(Column("mailbox_id") == mailboxId)
        .order(Column("date").desc)
        .limit(200)
        .fetchAll(db)
}

for try await snapshot in observation.values(in: dbPool) {
    // отдаём в UI; выполняется вне main actor, декорируем @MainActor-обёрткой
}
```

## Частые ошибки

- **Писать на `DatabasePool`-readerах** — crash. Запись только в `write { }`.
- **Держать `Row` вне транзакции** — использовать только внутри замыкания, наружу отдавать декодированные типы (`FetchableRecord`).
- **`ValueObservation` без `removeDuplicates`** — лишние обновления UI. Добавляем `.removeDuplicates()`.
- **Строковая интерполяция в SQL**: только bind (`?` или `:name`), иначе SQL injection.
- **Забыть `PRAGMA foreign_keys = ON`** — foreign key constraints молча игнорируются.
- **Тяжёлый observation на main actor** — рендер зависает. Декодируем в фоне, в UI — готовые структуры.

## Конкурентность

- `DatabasePool` — `Sendable`, можно держать как свойство actor.
- `write`/`read` — async, не блокируют вызывающий таск.
- Observability работает через callback-queue; async-вариант (`.values(in:)`) — предпочтительнее.

## Версии

- GRDB 7.x — минимум macOS 10.13, полностью совместим с macOS 14+.
- Поддержка strict concurrency в 7.x — да, но проверять warnings.

## Ссылки

- Repo: https://github.com/groue/GRDB.swift
- Docs: https://swiftpackageindex.com/groue/GRDB.swift/documentation
