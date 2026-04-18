# AI-pack: дизайн

**Дата**: 2026-04-17
**Статус**: approved for planning
**Автор**: brainstorming session
**Связанные документы**: [SPECIFICATION.md](../../../SPECIFICATION.md), [CONSTITUTION.md](../../../CONSTITUTION.md), [docs/AI.md](../../AI.md)

## Проблема

Пользователь тратит слишком много времени на разбор почты. Неважные рассылки смешаны с рабочими письмами в одном INBOX. Классические фильтры требуют навыков и не адаптируются.

## Решение

AI-pack — надстройка над v1 MailAi, которая:

1. Автоматически классифицирует новые письма на **Важное** и **Неважно** через AI (OpenRouter).
2. Показывает их в отдельных папках в sidebar («Отфильтрованные → Важное / Неважно»).
3. При ручном перетаскивании предлагает запомнить NL-правило.
4. Даёт пользователю управлять критериями в свободной форме (NL-правила в настройках).
5. Опционально синхронизирует папки с IMAP-сервером (по умолчанию локальные).

AI-pack выключен по умолчанию. Требует явного ввода OpenRouter API-ключа.

## Нерешаемые проблемы (out of scope)

- **NL-поиск** — не входит.
- **NL-bulk-действия** — не входят.
- **Локальная эвристика / детерминированный pre-filter** до AI — не входит. Все классификации идут через AI.
- **Авто-удаление** писем — запрещено конституцией. Только пользователь удаляет.

## Скоуп

### Что включено в v1 (каркас)

Правится `SPECIFICATION.md`, добавляются в `bd`:

- Секция sidebar «Отфильтрованные» с папками `Важное (0)` и `Неважно (0)`.
- Пустые empty states в этих папках с подсказкой «включите AI-pack в настройках».
- Зарезервированный слот прогресс-бара под header'ом списка писем (collapsed).
- Зарезервированный слот для sync-иконки в toolbar reader'а.
- Поле `Message.importance: Importance?` уже существует в `docs/Core.md`; остаётся `nil` во всех записях v1.
- Settings → «Отфильтрованные»: пункт-placeholder «AI-классификация — недоступно».

### Что включено в AI-pack (эта спека)

1. `AIProvider` + `OpenRouterClient` (стриминг, настраиваемая модель, заголовки).
2. `Classifier` — актор классификации на базе `AIProvider`.
3. Промпт v1 классификации + тесты на корпусе.
4. `ClassificationQueue` — фоновая очередь с батчингом, ретраями, persistence.
5. Schema v2 в `Storage`: таблицы `rules`, `classification_log`.
6. UI: прогресс-бар, sidebar-секция «Отфильтрованные» (живая), drag-to-rule sheet, Settings → AI-pack, sync-иконка.
7. `RuleEngine` — CRUD правил, сериализация в system-prompt.
8. Серверная синхронизация папок (опциональная, toggle).
9. Retention GC с тредовой связностью.
10. Тесты приватности (snippet ровно 150 символов, логи без PII).

### Что исключено

- NL-поиск, NL-bulk, локальная эвристика, авто-удаление.
- Авто-обучение без явного подтверждения (implicit training).
- Backfill серверных папок из MailAi (только miграция при явном toggle).

## Архитектура

### Модули и изменения

| Модуль | Изменения |
|---|---|
| `Core` | Типы `ClassificationInput`, `ClassificationResult`, `Rule`, `ConfidenceBand`, `Importance` (уже есть), `AuditEntry`. |
| `AI` | `AIProvider` (протокол), `OpenRouterClient` (реализация), `Classifier` (актор), `RuleEngine` (актор). |
| `Storage` | Миграция v2: `rules`, `classification_log`. Индекс `messages.importance`. Метод `runRetentionGC()`. |
| `AppShell` | `ClassificationQueue` (актор), интеграция триггеров. |
| `UI` | `FilteredSidebarSection`, `ClassificationProgressBar`, `SyncIndicator`, `RuleCreationSheet`, `AIPackSettingsView`. |
| `MailTransport` | Новые операции `createMailbox(path:)`, `move(messageIds:to:)` (уже в `MailTransportProtocol` — публикуем). |
| `Secrets` | Ключ `mailai.<accountId>.openrouter`. |

### Ключевые типы (Core)

```swift
public enum Importance: Int, Codable, Sendable {
    case important = 1
    case unimportant = 2
}

public struct ClassificationInput: Sendable {
    public let from: String
    public let to: [String]
    public let subject: String
    public let date: Date
    public let listUnsubscribe: Bool
    public let contentType: String
    public let bodySnippet: String  // ровно 150 символов plain text
    public let activeRules: [Rule]
}

public struct ClassificationResult: Sendable {
    public let importance: Importance
    public let confidence: Double
    public let matchedRule: Rule.ID?
    public let reasoning: String
    public let tokensIn: Int
    public let tokensOut: Int
    public let durationMs: Int
}

public struct Rule: Identifiable, Sendable, Codable {
    public enum Source: String, Codable, Sendable { case manual, dragConfirm, import }
    public enum Intent: String, Codable, Sendable { case markImportant, markUnimportant }
    public let id: UUID
    public var text: String
    public var intent: Intent
    public var enabled: Bool
    public let createdAt: Date
    public let source: Source
}
```

### Classifier (AI)

```swift
public actor Classifier {
    private let provider: AIProvider
    private let rules: RuleEngine
    private let log: ClassificationLog

    public func classify(messageId: Message.ID, input: ClassificationInput) async throws -> ClassificationResult
}
```

- Вход строится в `AppShell` из `Storage` (метаданные) + стриминг 150 символов тела из `MailTransport`.
- Выход записывается в `Storage.messages.importance` + `classification_log`.
- Ошибки: 3 ретрая с экспоненциальным backoff (1s, 2s, 4s). После — помечается `pending` и возвращается в очередь через час.

### ClassificationQueue (AppShell)

```swift
public actor ClassificationQueue {
    public struct Snapshot: Sendable {
        public let total: Int
        public let pending: Int
        public let failed: Int
        public let inFlight: Int
    }

    public func enqueue(_ ids: [Message.ID]) async
    public func observe() -> AsyncStream<Snapshot>
    public func pauseAll() async
    public func resumeAll() async
}
```

- Батчи по 10 писем, до 3 параллельных запросов.
- Pause при офлайне (через `NWPathMonitor` или ошибки URLSession).
- Persistence: очередь реконструируется при старте из `Storage` (`messages WHERE importance IS NULL AND date > now - 6mo`).
- Backfill при первом включении AI-pack: все непроклассифицированные письма в окне.

### Промпт классификации v1

System-prompt (подставляется в каждый запрос):

```
Ты — AI-классификатор почты. На каждое письмо отвечай строго в JSON:
{"importance": "important" | "unimportant", "confidence": 0.0-1.0, "reasoning": "одно короткое предложение на русском"}

Критерии:
- "important": рабочие письма от людей, счета, приглашения на встречи, ответы в тредах, уведомления о безопасности
- "unimportant": маркетинг, рассылки, автоматические уведомления сервисов, "дайджесты"

Дополнительные правила пользователя (если есть):
{{rules}}

Следуй правилам пользователя в первую очередь.
```

User-message:
```
From: {{from}}
To: {{to}}
Subject: {{subject}}
Date: {{date}}
List-Unsubscribe: {{has_or_no}}
Content-Type: {{content_type}}

Snippet (150 chars): {{body_snippet}}
```

### RuleEngine

- CRUD правил в `Storage.rules`.
- Активные правила сериализуются как буллеты в `{{rules}}` плейсхолдер. Лимит — 20 правил (~200 токенов). Если больше, фильтрация по релевантности: сперва правила с матчем по `from`-домену, затем по ключевым словам темы.
- Drag-to-rule: при дропе письма в папку → AI генерирует предложенный текст правила (отдельный промпт) → sheet пользователю.

### Server sync папок (опция)

Toggle в Settings. По умолчанию **выключен**.

- **Включение**:
  1. `MailTransport.createMailbox("Отфильтрованные/Важное")`, `"Отфильтрованные/Неважно"`.
  2. Батчевый MOVE всех уже классифицированных писем (по 50 с backoff).
  3. Прогресс в `SyncIndicator`.
- **Работа**:
  - После каждой `Classifier.classify()` → immediate MOVE на сервер.
  - Ручное перетаскивание → MOVE + создание правила (через sheet).
  - Undo: последние 20 MOVE в памяти, `⌘Z` возвращает.
- **Выключение**:
  - Диалог: «Оставить папки на сервере / Вернуть всё в INBOX».
  - Обратный MOVE — батчевый.

### Retention GC

- Триггер: раз в сутки при старте.
- SQL:
  ```sql
  WITH protected AS (
      SELECT DISTINCT thread_id FROM messages
      WHERE date >= datetime('now', '-6 months')
  )
  DELETE FROM messages
  WHERE date < datetime('now', '-6 months')
    AND thread_id NOT IN (SELECT thread_id FROM protected);
  ```
- VACUUM если удалено > 10%.
- Покрыт тестом с фикстурой смешанных дат.

## Data flow

```
IMAP IDLE / polling
  → new message detected
  → Storage.upsert(metadata)            // importance = nil
  → ClassificationQueue.enqueue(id)
  → (фон) Classifier.classify(input)
      input = metadata + 150-char snippet (stream из MailTransport)
      → AIProvider → OpenRouter
      → ClassificationResult
  → Storage.update(id, importance)
  → classification_log.append(meta)
  → ValueObservation → UI обновляет счётчики sidebar + progress-bar
  → (если server-sync on) MailTransport.move(id, to: target mailbox)
```

## Приватность (обязательные инварианты)

1. `bodySnippet` — **ровно 150 символов** plain text, без HTML-тегов, без quoted-reply (строки начинающиеся с `>`), без подписей (после `-- `). Функция извлечения — чистая, покрыта unit-тестами.
2. После `classify()` тело письма освобождается из памяти (snippet — строка в 150 символов, остаётся только до записи в лог).
3. `classification_log` содержит только: `{id_hash, model, tokens_in, tokens_out, duration_ms, confidence, matched_rule_id, error_code}`. Поля `from`, `subject`, `to`, `snippet`, содержимого ответа — **запрещены**.
4. Тест-инвариант: grep логов после end-to-end-теста → ни одного совпадения с фикстурными subject/from/snippet.
5. OpenRouter-ключ — только в Keychain (`mailai.<accountId>.openrouter`).

## UI

### Sidebar — новая секция

Между «Избранное» и «На моём Mac»:

```
Отфильтрованные
  ⭐ Важное            (N)
  📥 Неважно           (N)
```

Клик на папке — middle-колонка показывает виртуальный/серверный список (зависит от toggle server-sync).

### Progress-bar

- Под header'ом списка писем («Входящие — N писем…»).
- Тонкая линия + текст «Классифицируется N писем… ⏳».
- Autohide при `pending == 0`. При `failed > 0` — маленький бейдж с числом и клик → лог.

### Sync-иконка

- `arrow.triangle.2.circlepath` в правом верхнем углу toolbar'а reader'а.
- Состояния: hidden / animating / error-bedge. Tooltip с числом pending MOVE.

### Drag-to-rule sheet

Появляется после drop письма в папку классификации:

```
┌──────────────────────────────────────┐
│ Запомнить правило?                   │
│                                      │
│ [Письма от no-reply@openrouter.ai    │
│  считать Неважными            ]      │
│                                      │
│ [Запомнить] [Только это] [Отмена]    │
└──────────────────────────────────────┘
```

Текст редактируем, генерируется AI (отдельный короткий промпт «сформулируй правило по этому письму»).

### Settings → AI-pack

- Toggle «Включить AI-классификацию».
- Поле API-ключа OpenRouter (secret field, пишется в Keychain).
- Dropdown модели (подгружается через `GET /api/v1/models`, фильтр на дешёвые).
- Таблица правил (CRUD, toggle enable/disable).
- Счётчик «токенов/стоимости» за сессию и за месяц.
- Toggle «Синхронизировать папки с сервером».
- Кнопка «Экспорт правил» / «Импорт правил» (JSON).

## Бюджет и производительность

- **Модель по умолчанию** — настраиваема, рекомендуется `google/gemini-flash-lite` или эквивалент (≤$0.0001 на вызов).
- **Токены**: ~80 system + ~60 per-message = ~140 вход + 20 выход. Итого ~$0.00005–0.0002 на письмо.
- **Пропускная способность**: 3 параллельных запроса × 10 писем в батче ≈ 5 сек на батч. 1000 писем backfill — ~10 минут.
- **Latency UX**: новое письмо классифицируется в среднем за 2–5 сек после прихода. UI показывает прогресс, не блокируется.

## Тесты

### Unit

- Извлечение 150-char snippet: HTML-разбор, quoted-reply удаление, подпись удаление, ровно 150 символов (даже для длинного письма), корректность на кириллице.
- `Classifier.classify()` на моке `AIProvider`: happy path, ошибки, ретраи.
- `RuleEngine`: CRUD, сериализация в system-prompt, лимит 20.
- Retention GC: фикстура смешанных дат → protection тредов работает.
- Drag-to-rule: генерация текста правила на моке.

### Integration

- End-to-end: mock MailTransport → Storage → ClassificationQueue → mock AIProvider → Storage. Проверка, что `importance` проставлен, лог заполнен, прогресс-бар обновлён.
- Server-sync migration (on↔off) с mock `MailTransport`.

### Privacy invariants (обязательные)

- После прогона integration-теста grep лог-файла на subject/from из фикстуры — 0 совпадений.
- `bodySnippet` во всех инстанциях `ClassificationInput` имеет ровно 150 символов.
- Поиск по crash-dump/test artefact’ам: строки из тел писем не встречаются.

## Риски и митигации

| Риск | Митигация |
|---|---|
| OpenRouter меняет цены / недоступна модель | Настраиваемая модель, fallback на альтернативу, явный error-UI |
| Пользователь вводит неверный ключ | 401 → понятный UI, не retry-ить |
| Очередь растёт быстрее обработки | Визуальный progress + кнопка «Пауза» в настройках |
| Server-sync ломает поток пользователя (чужой клиент удивляется) | Toggle off по умолчанию, диалог при включении |
| Дрейф промпта / разные версии моделей | Версионирование промпта (`Prompts/classify-v1.txt`), A/B через feature-flag |
| Превышение контекста 20 правил | Фильтрация по релевантности, UI предупреждение «у вас много правил, актуальны Top-N» |
| Утечка body-snippet в логи | Инвариант-тест + pre-commit grep на имена полей в логгерах |

## Миграция существующего MVP

- **`SPECIFICATION.md`** — добавить раздел «UI-каркас AI-pack» в Scope v1: пустые папки, слоты, placeholder в Settings, acceptance-критерии.
- **`bd`** — одна новая задача P2 в Фазу A: «UI-каркас для AI-pack (пустые папки, слоты)». Блокирует C6 (acceptance MVP). Зависит от A3 (Sidebar) и A4 (Список).
- **`docs/AI.md`** — обновить: добавить ссылку на эту спеку, пометить `BulkDeleteAdvisor` как out-of-scope (был в v1 AI-пакете, теперь в будущем).
- **Эта спека** — отдельный файл, не смешиваем с основным SPECIFICATION.md.

## Definition of Done (AI-pack)

- AI-pack включается отдельным toggle, без ключа OpenRouter приложение работает.
- Новые письма классифицируются в фоне, UI показывает прогресс.
- Sidebar-секция «Отфильтрованные» показывает корректные счётчики.
- Drag-to-rule создаёт правило, правило применяется к следующим письмам.
- Retention GC сохраняет тредовую связность.
- Server-sync работает в обе стороны (on/off миграции).
- Все privacy-инварианты пройдены.
- SwiftLint / Strict Concurrency — 0 warnings.
- Задачи в `bd` закрыты (AI.1–AI.14).
