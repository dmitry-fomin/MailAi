# Модуль: AI

<!-- Статус: OpenRouterClient + Classifier actor + промпт ClassifyV1 + RuleEngine + SnippetExtractor + AI-pack settings (ключ/модель/правила) + drag-to-rule + серверная синхронизация Important/Unimportant реализованы. PromptStore + 14 шаблонов + ThreadSummarizer + ActionExtractor реализованы. BulkDeleteAdvisor / Usage — план. -->

## Sidebar и UX (AI-5)

- **«Отфильтрованные» — живые папки**: «Важное» и «Неважно» в sidebar
  собираются по `Importance`-меткам из `classification_log`, без отдельных
  IMAP-папок (для серверной синхронизации см. AI-7). Пересчёт идёт по
  событиям `RuleEngine`/`Classifier`.
- **`ClassificationProgressBar` (`Packages/UI`)**: тонкая HUD-полоска под
  тулбаром, биндится к `ClassificationProgressViewModel` (AppShell). Показывает
  «N из M писем классифицируются» во время батча `ClassificationQueue`;
  при пустой очереди скрывается. Текстов писем не отображает.
- **Drag-to-rule**: письмо можно перетащить из списка в «Важное»/«Неважно»
  в sidebar. Перенос инициирует `RuleProposalSheet` — лист с предзаполненным
  кандидатом-правилом (`from:` или `subject contains:`). Только метаданные
  (`DraggableMessage`: id, from, fromName, subject) — никогда тело/snippet.
  UTI: `ai.mailai.message`.

## Settings → AI-pack (AI-6)

`SettingsScene` содержит вкладку «AI-pack», по аккаунту:

- **OpenRouter API key**: `SecureField`, сохраняется через
  `SecretsStore.setOpenRouterKey(_:forAccount:)` в Keychain. На UI отображается
  только маска «задан/не задан».
- **Model picker**: список `OpenRouterModelCatalog.all` (id, displayName,
  context window). Дефолт — `OpenRouterModelCatalog.defaultModelID`.
- **Toggle `aiPackEnabled`**: включает классификацию по аккаунту. Если включён,
  но API-ключ пуст — UI подсвечивает блокер, классификация не стартует.
- **Toggle `serverSyncEnabled`**: включает AI-7 (серверный move
  Important/Unimportant). Disabled, пока `aiPackEnabled == false`.
- **CRUD правил**: список `Rule` из `RulesRepository`, добавление/удаление,
  изменение `intent` (markImportant / markUnimportant). Сериализация в system
  prompt — на стороне `RuleEngine`.

State: `AISettingsViewModel` (`@MainActor`, `ObservableObject`) +
`AISettingsStore` (actor, persists toggles на диск, секреты — в Keychain).

## Серверная синхронизация Important/Unimportant (AI-7)

Опционально (управляется `serverSyncEnabled`). Пишем результат
классификации в две IMAP-папки на сервере: `MailAi/Important` и
`MailAi/Unimportant`. Это даёт согласованность между устройствами и Mail.app.

- **`IMAPServerFolderSync.Target`** (enum, `important`/`unimportant`) +
  `IMAPServerFolderSync.path(for:delimiter:)` — строит полный путь под
  серверный hierarchy delimiter из `LIST`.
- **`LiveAccountDataProvider.ensureServerFolders()`** — идемпотентно создаёт
  обе папки (`CREATE`), `alreadyExists` считается успехом, `failed` не
  блокирует классификацию (молча пропускает). Кэш `serverFoldersEnsured`
  живёт ровно столько, сколько провайдер.
- **`LiveAccountDataProvider.moveAfterClassification(messageID:target:)`** —
  при наличии capability `MOVE` использует `UID MOVE`, иначе fallback
  `UID COPY` + `STORE +FLAGS \Deleted` + `EXPUNGE`. После переноса локальная
  запись удаляется из `MetadataStore`.
- **Hook**: `ClassificationCoordinator.postClassifyHook` — `(@Sendable (Message.ID, Importance) async -> Void)?`,
  вызывается после успешного `RuleEngine`-вердикта. Приложение подключает
  туда вызов `moveAfterClassification(...)`. Хук опционален — без него работает
  чисто локальный режим (AI-5).
- **Backfill** старых писем в новые серверные папки не делается — переносим
  только новопришедшие/перерасклассифицированные.

## Назначение

Клиент к OpenRouter, промпты и высокоуровневые сценарии: суммаризация переписки, оценка важности, классификация, поиск кандидатов на массовое удаление по запросу («удали все рассылки за полгода»).

## Система промптов

### Архитектура

Промпты разделены на два слоя:

1. **Инструкция** — хранится в `.md`-файле (`~/.mailai/prompts/{id}.md`). Описывает роль модели, контекст письма через плейсхолдеры (`{{FROM}}`, `{{SUBJECT}}`, `{{BODY}}` и т.д.) и критерии ответа. Пользователь может редактировать эти файлы напрямую.
2. **Формат ответа** — хардкод в Swift-акторе (`private static let responseFormat`). Задаёт JSON-схему, которую должна вернуть модель. Парсится в типизированные структуры на стороне кода.

Итоговый system-промпт = инструкция + `\n\n` + формат ответа.

### PromptStore

`PromptStore` (actor, `Sources/AI/PromptStore.swift`) управляет файлами промптов:

| Метод | Назначение |
|-------|-----------|
| `initializeDefaults()` | При первом запуске копирует все 14 бандловых `.md` в `~/.mailai/prompts/`. Существующие файлы не трогает. |
| `load(id:)` | Загружает файл из `~/.mailai/prompts/`; если отсутствует — fallback на бандл. |
| `save(id:content:)` | Сохраняет пользовательский override. |
| `reset(id:)` | Перезаписывает файл из бандла, откатывая пользовательские правки. |
| `isCustom(id:)` | Возвращает `true`, если пользователь переопределил промпт. |

`initializeDefaults()` вызывается в `AppDelegate.applicationDidFinishLaunching`. Сбой не крашит приложение (`try?`) — при следующем `load()` сработает bundle-fallback.

### Реестр промптов

`PromptEntry.allEntries` (`Sources/AI/PromptEntry.swift`) — источник истины о всех 14 промптах: id, SF Symbol, отображаемое имя.

| id | Назначение | Плейсхолдеры |
|----|-----------|--------------|
| `classify` | Важное / неважное / рассылка | `{{FROM}}`, `{{SUBJECT}}`, `{{SNIPPET}}` |
| `summarize` | Суммаризация треда | `{{THREAD}}` |
| `extract_actions` | Дедлайны, задачи, встречи, ссылки | `{{BODY}}` |
| `quick_reply` | 3 варианта ответа | `{{FROM}}`, `{{SUBJECT}}`, `{{BODY}}` |
| `bulk_delete` | Кандидаты на удаление | `{{MESSAGES}}` |
| `translate` | Перевод письма | `{{BODY}}`, `{{TARGET_LANGUAGE}}` |
| `categorize` | Категория, язык, тон | `{{FROM}}`, `{{SUBJECT}}`, `{{SNIPPET}}` |
| `snooze` | Когда вернуться к письму | `{{FROM}}`, `{{SUBJECT}}`, `{{DATE}}`, `{{BODY}}` |
| `snippet` | Однострочный AI-превью (≤120 символов) | `{{FROM}}`, `{{SUBJECT}}`, `{{BODY}}` |
| `draft_coach` | Правки черновика | `{{SUBJECT}}`, `{{DRAFT}}` |
| `nl_search` | NL-запрос → параметры поиска | `{{QUERY}}` |
| `follow_up` | Нужен ли follow-up и когда | `{{FROM}}`, `{{SUBJECT}}`, `{{DATE}}`, `{{BODY}}` |
| `attachment_summary` | Суммаризация вложения | `{{FILENAME}}`, `{{CONTENT}}` |
| `meeting_parser` | Детали встречи из письма | `{{SUBJECT}}`, `{{BODY}}` |

### JSON-схемы ответов (в Swift-коде)

| id | Схема |
|----|-------|
| `classify` | `{"importance": "important\|unimportant\|newsletter", "reason": "..."}` |
| `summarize` | `{"summary": "...", "participants": [...], "keyPoints": [...]}` |
| `extract_actions` | `[{"kind": "deadline\|task\|meeting\|link\|question", "text": "...", "dueDate": "ISO8601\|null"}]` |
| `quick_reply` | `{"replies": [{"tone": "accept\|decline\|clarify", "text": "..."}]}` |
| `bulk_delete` | `[{"messageId": "...", "reason": "..."}]` |
| `translate` | `{"translation": "...", "detectedLanguage": "..."}` |
| `categorize` | `{"category": "...", "language": "...", "tone": "..."}` |
| `snooze` | `{"suggestAt": "ISO8601", "reason": "..."}` |
| `snippet` | `{"snippet": "..."}` |
| `draft_coach` | `{"suggestions": [{"field": "tone\|clarity\|cta\|grammar", "comment": "...", "suggestion": "..."}]}` |
| `nl_search` | `{"from": "...", "to": "...", "after": "ISO8601\|null", "before": "ISO8601\|null", "keywords": [...], "subject": "...", "hasAttachment": bool\|null, "label": "..."}` |
| `follow_up` | `{"needsFollowUp": bool, "suggestAt": "ISO8601\|null", "reason": "..."}` |
| `attachment_summary` | `{"summary": "...", "keyPoints": [...], "actionItems": [...]}` |
| `meeting_parser` | `{"title": "...", "date": "ISO8601\|null", "timezone": "...", "duration": "...", "location": "...", "organizer": "...", "attendees": [...], "agenda": [...], "dialIn": "..."}` |

## Ключевые сущности

- `OpenRouterClient` — HTTP-клиент (URLSession + async/await), модель настраивается пользователем.
- `PromptStore` — actor, управляет `.md`-файлами промптов в `~/.mailai/prompts/`.
- `PromptEntry` — метаданные промпта: id, иконка, имя; `allEntries` — реестр всех 14 промптов.
- `ThreadSummarizer` — суммаризация треда, загружает инструкцию из `PromptStore`.
- `ActionExtractor` — извлечение действий из письма, загружает инструкцию из `PromptStore`.
- `ImportanceRater` — оценка важности входящих (важное/неважное/рассылка). _(план)_
- `BulkDeleteAdvisor` — строит план удаления по запросу пользователя. _(план)_
- `Usage` — счётчики токенов/стоимости на сессию. _(план)_

## Бизнес-логика

- **Приватность — жёсткое требование.** Тело письма отправляется в OpenRouter **только** в момент активного запроса пользователя и не кешируется после ответа.
- **Экономия**: суммаризации кешируются **по хешу тела** в метаданных (не само тело!) — повторная суммаризация того же письма не идёт в сеть.
- **Streaming-ответы** от модели, чтобы UI получал результат сразу.
- **Массовое удаление** — двухшаговое: (1) AI предлагает кандидатов, (2) пользователь подтверждает. Удаление без подтверждения запрещено.
- **Rate limiting / retries** — экспоненциальный backoff, уважение `Retry-After`.
- **Отмена** — все операции `Task`-отменяемы.

## API

```swift
public protocol AIProvider: Sendable {
    func summarize(thread: MessageBody) async throws -> String
    func rateImportance(_ headers: [Message]) async throws -> [Message.ID: Importance]
    func suggestBulkDelete(query: String, candidates: [Message]) async throws -> BulkDeletePlan
}
```

## Зависимости

- **От**: `Core`, `Secrets` (API-ключ OpenRouter).
- **Кто зависит**: `AppShell`.

## Запрещено

- Кешировать ответы AI вместе с телами писем.
- Логировать содержимое промптов и ответов (только метрики: токены, длительность, код ошибки).
- Отправлять что-либо в OpenRouter без явного пользовательского действия.
