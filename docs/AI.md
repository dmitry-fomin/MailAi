# Модуль: AI

<!-- Статус: OpenRouterClient + Classifier actor + промпт ClassifyV1 + RuleEngine + SnippetExtractor + AI-pack settings (ключ/модель/правила) + drag-to-rule + серверная синхронизация Important/Unimportant реализованы. Summarizer / BulkDeleteAdvisor / Usage — план. -->

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

## Ключевые сущности

- `OpenRouterClient` — HTTP-клиент (URLSession + async/await), модель настраивается пользователем.
- `Prompt` — шаблон с плейсхолдерами, версионируется.
- `Summarizer` — сервис суммаризации треда.
- `ImportanceRater` — оценка важности входящих (важное/неважное/рассылка).
- `BulkDeleteAdvisor` — строит план удаления по запросу пользователя, возвращает список кандидатов для подтверждения.
- `Usage` — счётчики токенов/стоимости на сессию.

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
