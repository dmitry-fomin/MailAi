# Модуль: Search

<!-- Статус: план модуля. Код ещё не написан. -->

## Назначение

Локальный поиск по метаданным и серверный поиск по телам писем. Быстрый отклик на типичные запросы («от X», «за неделю», «с вложениями») плюс fallback на server-side search.

## Ключевые сущности

- `SearchIndex` — FTS5-индекс в той же БД, что и `Storage`. Индексируется: `from`, `to`, `subject`, `snippet` (первые N символов темы + AI-summary, **если уже есть**; само тело не индексируется).
- `QueryParser` — разбор пользовательского запроса (операторы: `from:`, `has:attachment`, `before:`, `is:unread`, свободный текст).
- `LocalSearcher` — выполняет запрос по FTS5.
- `ServerSearcher` — IMAP SEARCH / Exchange `$search`, когда нужен поиск по полному телу.
- `SearchCoordinator` — оркестрирует local-first, затем server-side если результатов мало.

## Бизнес-логика

- **Local-first**: сначала локальный индекс (мгновенно), параллельно — серверный запрос.
- **Debounce** 200 мс для live-поиска.
- **Инкрементальная индексация**: новые письма индексируются при upsert в `Storage`.
- Результаты — стрим, UI показывает частичные совпадения по мере поступления.

## API

```swift
public protocol SearchService: Sendable {
    func search(_ query: String, in: Account.ID) -> AsyncStream<SearchResult>
}
```

## Зависимости

- **От**: `Core`, `Storage`, `MailTransport`.
- **Кто зависит**: `AppShell`.

## Запрещено

- Индексировать тела писем (только то, что уже и так в метаданных / AI-summary).
