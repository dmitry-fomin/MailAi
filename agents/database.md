# Агент: Database

## Область

Локальное хранилище метаданных писем. Предварительно — **GRDB** поверх SQLite; при обоснованном отказе свернём на чистый SQLite через C-API.

## Принципиальное ограничение

**В БД хранятся только метаданные.** Тела писем, вложения, любые фрагменты текста писем — никогда. Нарушение этого правила — блокирующая ошибка.

## Структура

- Один файл БД на аккаунт: `~/Library/Application Support/MailAi/<accountId>.sqlite`.
- Изоляция окон-аккаунтов: каждое окно открывает свою БД, пулы соединений не делим.
- WAL mode (`PRAGMA journal_mode = WAL;`) для одновременного чтения/записи.
- Foreign keys включены (`PRAGMA foreign_keys = ON;`).

## Таблицы (MVP)

- `accounts` — id (uuid), type, email, display_name, keychain_ref.
- `mailboxes` — id, account_id, path, role, uid_validity, total_count, unread_count.
- `messages` — id (uuid), account_id, mailbox_id, uid, message_id, from_addr, from_name, subject, date, flags, size, has_attachments, importance, thread_id, summary_hash (nullable).
- `threads` — id, account_id, subject_norm, last_date.
- `settings` — key/value для настроек аккаунта (policies, фильтры уведомлений).

## Индексы

- `(account_id, mailbox_id, date DESC)` — главный индекс для списков.
- `(account_id, thread_id)` — группировка тредов.
- `(message_id)` — unique для дедупликации.
- FTS5-индекс для `Search`: `from`, `to`, `subject`, `summary_text` (если AI-summary уже есть).

## Миграции

- Версионирование через GRDB `DatabaseMigrator`.
- Вперёд — всегда совместимо. Назад — не поддерживаем (downgrade через удаление БД).
- Каждая миграция покрыта тестом на fixture старой версии.

## Работа с GRDB

- `DatabaseQueue` для однопоточных сценариев, `DatabasePool` для читатели/писатели.
- Наблюдение — `ValueObservation` → обёртка в `AsyncStream`.
- Транзакции обязательны для batch-операций upsert.
- Prepared statements — через GRDB query interface, не concat строк.

## Производительность

- Batch-inserts порциями по 500 записей.
- `EXPLAIN QUERY PLAN` для тяжёлых запросов в тестах.
- Пересчёт счётчиков — инкрементально (триггерами или в коде), не `COUNT(*)` на каждый UI-refresh.
- Vacuum — раз в N запусков или при сильной фрагментации.

## Запрещено

- SQL-строки с интерполяцией параметров (только bind).
- Хранение тел писем, HTML, text-частей, base64 вложений.
- Хранение паролей / токенов / API-ключей (это — Keychain).
- Один файл БД для нескольких аккаунтов.
