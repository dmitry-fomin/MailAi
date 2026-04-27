# Дизайн: AI Feature Pack 2

Дата: 2026-04-27. Статус: draft.

Расширяет существующий AI-pack (классификация Important/Unimportant + правила)
восемью новыми сценариями. Все используют один `AIProvider` (OpenRouter).

## Общие принципы

1. **Privacy = конституция**: тело письма отправляется в AI только при явном
   действии пользователя (кнопка, подтверждение). Результаты кешируются по
   SHA-256 хешу тела — не по самому телу.
2. **Один AIProvider**: все 8 фич делят `OpenRouterClient`, модель выбирается
   в Settings. Для тяжёлых задач (перевод, bulk-delete) можно override модели
   на более мощную.
3. **Streaming**: ответы приходят по SSE, UI показывает typing-индикатор.
4. **Cancel**: любая AI-операция отменяема через `Task.cancel()`.
5. **Кеширование в Storage**: таблица `ai_cache` — key=SHA-256(prompt), value=JSON
   результат, expires_at. Тела нет, только результат. TTL: суммаризация 7 дней,
   сниппет 30 дней, категории 14 дней.

---

## A. Суммаризация треда

### Суть
Кнопка «Суммаризовать» в reader header. AI анализирует все письма треда
(до 10 последних) и выдаёт 2-3 предложения: кто, что, какие решения.

### Протокол (расширение Core)
```swift
// Core/Protocols/AIProvider.swift — добавить
public protocol AISummarizer: Sendable {
    func summarize(messages: [MessageSummaryInput]) async throws -> Summary
}

public struct MessageSummaryInput: Sendable {
    public let from: String
    public let date: Date
    public let bodySnippet: String  // 300 chars
}

public struct Summary: Sendable, Identifiable {
    public let id: UUID
    public let text: String          // 2-3 предложения
    public let participants: [String] // уникальные отправители
    public let keyPoints: [String]    // 1-3 bullet points
    public let tokensIn: Int
    public let tokensOut: Int
}
```

### Промпт (SummarizeV1)
System: «Ты — ассистент почты. Суммаризуй переписку в 2-3 предложения.
Выдели: кто участвовал, что обсуждали, какие решения приняты.
Формат: JSON {summary, participants, keyPoints}»
User: хронологический список сообщений (from, date, snippet 300 chars).

### UI
- Кнопка «✨ Суммаризовать» в ReaderHeaderView (рядом с датой).
- Нажатие → streaming ответ → показывается в карточке над телом письма.
- Повторный клик — свернуть/развернуть.
- Результат кешируется по SHA-256(messageIDs + bodies).

### Storage
Таблица `ai_cache`:
```
id TEXT PK, feature TEXT NOT NULL,  -- 'summary'
cache_key TEXT NOT NULL,            -- SHA-256(message_ids joined)
result_json TEXT NOT NULL,          -- {summary, participants, keyPoints}
created_at DATETIME NOT NULL,
expires_at DATETIME NOT NULL
```

---

## B. Quick Reply (быстрый ответ)

### Суть
Кнопка в reader → AI генерирует 3 варианта короткого ответа (до 50 слов).
Пользователь выбирает один → подставляется в ComposeScene.

### Протокол
```swift
public protocol AIQuickReplier: Sendable {
    func suggestReplies(
        originalMessage: MessageSummaryInput,
        tone: ReplyTone
    ) async throws -> [ReplySuggestion]
}

public enum ReplyTone: String, Sendable, CaseIterable {
    case formal, friendly, concise
}

public struct ReplySuggestion: Sendable, Identifiable {
    public let id: UUID
    public let text: String       // до 50 слов
    public let tone: ReplyTone
}
```

### Промпт
System: «Ты — ассистент почты. Предложи 3 варианта короткого ответа
(до 50 слов каждый) на письмо. Тон: {tone}. Формат: JSON {replies: [{text, tone}]}»
User: from + subject + body snippet (300 chars) оригинала.

### UI
- Кнопка «⚡ Ответить» в ReaderToolbar (рядом с обычной reply).
- Нажатие → popover с 3 вариантами + selector тона (formal/friendly/concise).
- Клик на вариант → открывается ComposeScene с предзаполненным телом.
- Результат НЕ кешируется (контекстуальный).

---

## C. AI-сниппет для списка писем

### Суть
Вместо `preview` (первые 150 символов тела) — AI-генерированная однострочная
выжимка. Показывается в `MessageRowView`. Кешируется.

### Протокол
```swift
public protocol AISnippetGenerator: Sendable {
    func generateSnippet(input: ClassificationInput) async throws -> String
}
```

### Промпт
System: «Создай однострочную выжимку письма (до 80 символов) для preview
в списке писем. Только суть, без воды. Формат: plain text, одна строка.»
User: те же поля что ClassificationInput.

### UI
- `MessageRowView`: если `message.aiSnippet != nil` — показываем его вместо
  `message.preview`. Шрифт — secondary, italic.
- Генерация: batch в фоне при первой загрузке писем (через ClassificationQueue).
- Toggle в Settings: «AI-превью писем» (по умолчанию off — стоит токены).

### Storage
Колонка `ai_snippet` в таблице `message` (SchemaV4). TEXT, nullable.
Кеш в `ai_cache` с feature='snippet'.

---

## E. Bulk-delete advisor

### Суть
Пользователь пишет запрос: «Удали все рассылки за полгода» / «Удали маркетинг».
AI анализирует метаданные писем, отмечает кандидатов, пользователь подтверждает.

### Протокол
```swift
public protocol AIBulkAdvisor: Sendable {
    func suggestBulkAction(
        query: String,
        candidates: [BulkCandidate]
    ) async throws -> BulkActionPlan
}

public struct BulkCandidate: Sendable {
    public let messageID: Message.ID
    public let from: String
    public let subject: String
    public let date: Date
    public let importance: Importance
}

public struct BulkActionPlan: Sendable, Identifiable {
    public let id: UUID
    public let query: String
    public let messageIDs: [Message.ID]
    public let reasoning: String
    public let count: Int
}
```

### Промпт
System: «Ты — ассистент очистки почты. Пользователь просит удалить письма.
Верни JSON {message_ids: [...], reasoning, count}. Удаляй только если
уверен. Если сомневаешься — не включай.»
User: запрос + массив (from, subject, date, importance) до 200 писем.

### UI
- Отдельное окно/panel: текстовое поле «Что удалить?» + кнопка «Найти».
- Результат: список писем с чекбоксами + reasoning.
- Кнопка «Удалить N писем» → подтверждение → массовый UID STORE + EXPUNGE.
- Двухшаговый: AI предлагает → пользователь подтверждает. Без подтверждения
  удаление запрещено (конституция).

---

## G. Перевод письма

### Суть
Кнопка «Перевести» в reader → AI переводит тело на язык интерфейса.
Результат временный — не пишется на диск.

### Протокол
```swift
public protocol AITranslator: Sendable {
    func translate(
        body: String,
        contentType: String,
        targetLanguage: String
    ) async throws -> Translation
}

public struct Translation: Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let detectedLanguage: String
    public let targetLanguage: String
}
```

### Промпт
System: «Переведи текст письма на {targetLanguage}. Сохрани форматирование.
Определи исходный язык. JSON: {text, detectedLanguage, targetLanguage}»
User: полное тело письма (plain text после strip HTML).

### UI
- Кнопка «🌐 Перевести» в ReaderToolbar.
- Нажатие → streaming → показывается переведённый текст вместо оригинала.
- Toggle «Оригинал / Перевод» для переключения.
- Тело загружается по требованию (уже есть `body(for:)`).
- Перевод живёт ТОЛЬКО в @State, на диск не пишется (приватность!).

### Важно: тело в AI
Это единственная фича, где ПОЛНОЕ тело уходит в AI. Подтверждается кнопкой.
Никакого автоперевода — только по клику.

---

## H. Извлечение действий (Action Items)

### Суть
AI парсит письмо и вытаскивает: дедлайны, задачи, встречи, ссылки.
Показывает как чек-лист над телом письма.

### Протокол
```swift
public protocol AIActionExtractor: Sendable {
    func extractActions(
        from message: MessageSummaryInput
    ) async throws -> [ActionItem]
}

public enum ActionKind: String, Sendable, Codable {
    case deadline, task, meeting, link, question
}

public struct ActionItem: Sendable, Identifiable, Codable {
    public let id: UUID
    public let kind: ActionKind
    public let text: String
    public let dueDate: Date?
    public let isCompleted: Bool
}
```

### Промпт
System: «Извлеки действия из письма: дедлайны, задачи, встречи, важные ссылки,
вопросы требующие ответа. JSON: {actions: [{kind, text, dueDate}]}»
User: from + subject + body snippet (300 chars).

### UI
- Кнопка «📋 Действия» в ReaderToolbar.
- Результат: collapsible карточка над телом с чек-листом.
- Чекбоксы — локальное состояние, можно отметить «выполнено».
- Кешируется в `ai_cache` по SHA-256(message_id + body).

---

## I. Категории писем (AI Labels)

### Суть
Авто-лайблинг: Finance, Travel, Social, Work, Legal, Receipt, Notification,
Personal. В sidebar секция «Категории» с папками.

### Протокол
```swift
public enum MessageCategory: String, Sendable, Codable, CaseIterable {
    case work, finance, travel, social, legal
    case receipt, notification, personal, marketing, other
}

// Расширение ClassificationResult:
public struct ClassificationResult {
    // ... existing fields ...
    public var category: MessageCategory?
    public var language: String?      // iso 639-1
    public var tone: MessageTone?
}

public enum MessageTone: String, Sendable, Codable {
    case urgent, formal, friendly, neutral, marketing
}
```

### Промпт
Расширение ClassifyV1: добавляем в JSON-ответ поля category, language, tone.
Один вызов — все три поля. Cost: ~20 доп. токенов на ответ.

### UI
- Sidebar: секция «Категории» с иконками и счётчиками.
- MessageRowView: бейдж категории слева (маленький цветной dot).
- Filter: клик по категории фильтрует текущий список.
- Settings: toggle «AI-категории» (по умолчанию off).

### Storage
Колонки в `message`: `category TEXT` и `tone TEXT` (SchemaV4).

---

## J. Snooze с AI-подсказкой

### Суть
«Напомнить когда...» → AI определяет из текста письма дату/событие
и предлагает snooze до нужного момента.

### Протокол
```swift
public protocol AISnoozeSuggester: Sendable {
    func suggestSnooze(
        message: MessageSummaryInput
    ) async throws -> SnoozeSuggestion?
}

public struct SnoozeSuggestion: Sendable {
    public let suggestedDate: Date
    public let reason: String  // «Дедлайн проекта 15 мая»
}
```

### Промпт
System: «Проанализируй письмо. Если есть конкретная дата, дедлайн,
запланированное событие — предложи когда напомнить. Если нет — верни null.
JSON: {suggestedDate: ISO8601 или null, reason: string или null}»

### UI
- Контекстное меню на письме: «⏰ Напомнить...»
- Если AI нашёл дату → показывает suggestion «Напомнить 15 мая (дедлайн)».
- Ручной snooze: date picker + пресеты (завтра, через 3 дня, через неделю).
- Snoozed письма убираются из списка, возвращаются в назначенное время.

### Storage
Таблица `snoozed_messages`:
```
message_id TEXT PK, snooze_until DATETIME NOT NULL,
original_mailbox_id TEXT NOT NULL, created_at DATETIME NOT NULL
```

### Механизм
Timer/fetch каждые 5 минут → если `snooze_until <= now` → вернуть письмо
в список + показать уведомление.

---

## K. Контактная книга AI

### Суть
AI строит профили отправителей: частота, темы, среднее время ответа,
последний контакт. Доступно из контекстного меню на отправителе.

### Протокол
```swift
public struct SenderProfile: Sendable, Identifiable {
    public let id: String  // email address
    public let name: String?
    public let totalMessages: Int
    public let lastContactDate: Date?
    public let avgResponseHours: Double?
    public let topTopics: [String]      // до 5
    public let importance: Importance   // aggregated
    public let categoryBreakdown: [MessageCategory: Int]
}

public protocol AIContactProfiler: Sendable {
    func profile(for address: String, messages: [Message]) async throws -> SenderProfile
}
```

### Реализация
- НЕ делает дополнительных запросов к AI.
- Агрегирует из существующих данных: `message` (from, subject, date, importance, category).
- `topTopics`: берём 5 самых частых слов из subject'ов (после стоп-слов) —
  без AI, TF-IDF локально. Быстро, без токенов.
- `avgResponseHours`: если есть треды — разница между датами ответов.

### UI
- Клик на аватар/имя отправителя в ReaderHeaderView → popover с профилем.
- Показывает: имя, email, N писем, последний контакт, топ-3 темы,
  метка Important/Unimportant.
- Кнопка «Все письма от...» → фильтр в списке.

### Storage
Никаких новых таблиц — запросы на лету из `message`.
Опциональный кеш: `ai_cache` с feature='profile', key=SHA-256(email).

---

## Storage SchemaV4 (миграция)

```sql
-- Новые колонки в message
ALTER TABLE message ADD COLUMN ai_snippet TEXT;
ALTER TABLE message ADD COLUMN category TEXT;
ALTER TABLE message ADD COLUMN tone TEXT;

-- Кеш AI-результатов
CREATE TABLE ai_cache (
    id TEXT PRIMARY KEY NOT NULL,
    feature TEXT NOT NULL,          -- 'summary', 'snippet', 'actions', 'profile'
    cache_key TEXT NOT NULL,        -- SHA-256(prompt inputs)
    result_json TEXT NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL
);
CREATE INDEX idx_ai_cache_lookup ON ai_cache(feature, cache_key);

-- Snooze
CREATE TABLE snoozed_messages (
    message_id TEXT PRIMARY KEY NOT NULL,
    snooze_until DATETIME NOT NULL,
    original_mailbox_id TEXT NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_snooze_until ON snoozed_messages(snooze_until);
```

## Порядок реализации

Фаза 1 (ядро):
1. **SchemaV4** — миграция + ai_cache
2. **P: Prompt Editor** — PromptStore + bundled defaults + Settings UI
3. **A: Суммаризация** — killer feature, протокол заглушка уже есть
4. **H: Action Items** — маленький промпт, большой value

Фаза 2 (productivity):
5. **B: Quick Reply** — wow-эффект
6. **I: Категории** — расширение ClassifyV1 (бесплатно)
7. **E: Bulk-delete** — двухшаговый, самый сложный UI

Фаза 3 (nice-to-have):
8. **G: Перевод** — простое, но полное тело в AI
9. **C: AI-сниппет** — batch, затратный по токенам
10. **J: Snooze** — новая механика (timer, возврат)
11. **K: Профили** — агрегация без AI-запросов

## Зависимости

```
SchemaV4 ──→ A (summary), B (quick reply), C (snippet),
             E (bulk), H (actions), I (categories),
             J (snooze)

P (prompt editor) ──→ независима (можно делать параллельно со SchemaV4)
  но все AI-фичи должны инжектить PromptStore вместо хардкода промптов

A (summary) ──→ независима
B (quick reply) ──→ зависит от Compose integration
C (snippet) ──→ зависит от SchemaV4 (колонка ai_snippet)
E (bulk-delete) ──→ зависит от MailActionsProvider.delete
G (translate) ──→ независима
H (actions) ──→ зависит от SchemaV4
I (categories) ──→ расширение Classifier (один вызов)
J (snooze) ──→ зависит от SchemaV4 + timer mechanism
K (profiles) ──→ независима (чистая агрегация)
```

## P. Prompt Editor (редактор промптов в Settings)

### Суть
Master-detail UI для редактирования всех AI-промптов пользователем.
Аналогично редактированию подписей в стандартном Mail.app:
левая колонка — список промптов с иконками, правая — текстовый редактор.

### Редактируемые промпты (9 шт.)

| Файл | Иконка (SF Symbol) | Название |
|---|---|---|
| `classify.md` | `tag` | Классификация |
| `summarize.md` | `doc.text.magnifyingglass` | Суммаризация |
| `extract_actions.md` | `checklist` | Действия |
| `quick_reply.md` | `bubble.left.and.bubble.right` | Быстрый ответ |
| `bulk_delete.md` | `trash.circle` | Массовое удаление |
| `translate.md` | `globe` | Перевод |
| `categorize.md` | `folder.badge.gearshape` | Категории |
| `snooze.md` | `alarm` | Напоминания |
| `snippet.md` | `text.alignleft` | AI-превью |

### Хранение файлов

```
~/.mailai/
└── prompts/
    ├── classify.md       # пользовательский override (может не быть)
    ├── summarize.md
    ├── extract_actions.md
    ├── quick_reply.md
    ├── bulk_delete.md
    ├── translate.md
    ├── categorize.md
    ├── snooze.md
    └── snippet.md
```

**Механика:**
1. **Дефолтные промпты**: bundled в app bundle
   (`Packages/AI/Resources/Prompts/*.md` — SwiftPM resource).
2. **Пользовательские правки**: `~/.mailai/prompts/*.md`.
3. **Загрузка**: `PromptStore.load("summarize")` →
   если `~/.mailai/prompts/summarize.md` существует → читаем его,
   иначе → читаем bundled default.
4. **Сохранение**: `PromptStore.save("summarize", text)` →
   записывает в `~/.mailai/prompts/summarize.md`,
   создаёт директорию если нет.
5. **Reset**: `PromptStore.reset("summarize")` →
   `rm ~/.mailai/prompts/summarize.md` → следующий load вернёт bundled.
6. **isCustom**: сравнение с bundled (хеш или пофайловое).

### Протокол

```swift
/// Чтение/запись промптов. Thread-safe.
public protocol PromptStore: Sendable {
    /// Загрузить промпт (кастомный или дефолтный).
    func load(_ name: String) async throws -> String
    /// Сохранить кастомный промпт.
    func save(_ name: String, content: String) async throws
    /// Сбросить к дефолтному (удалить кастомный файл).
    func reset(_ name: String) async throws
    /// Отличается ли от дефолта?
    func isCustom(_ name: String) async throws -> Bool
    /// Список всех промптов с метаданными.
    func listAll() async throws -> [PromptEntry]
}

public struct PromptEntry: Sendable, Identifiable {
    public let id: String           // 'summarize', 'classify', ...
    public let icon: String         // SF Symbol name
    public let displayName: String  // «Суммаризация»
    public var content: String      // текущий текст
    public var isCustom: Bool       // отличается от дефолта?
}
```

### UI

```
┌─────────────────────────────────────────────────┐
│ Settings → AI Промпты                           │
├──────────────┬──────────────────────────────────┤
│ 🏷 Классиф.  │  System prompt для классификации │
│ 🔍 Суммар.   │  писем на Important/Unimportant. │
│ ✅ Действия   │                                  │
│ 💬 Ответ     │  Анализируй: от кого, тема,      │
│ 🗑 Удаление  │  snippet. Формат: JSON {          │
│ 🌐 Перевод   │    "importance": "...",           │
│ 📁 Категории │    "confidence": 0.0-1.0,         │
│ ⏰ Напомин.  │    "reasoning": "..."             │
│ 📝 Превью    │  }                                │
│              │                                  │
│              │  ─────────────────────────────── │
│              │  ● Изменён    [Сбросить к стандарту] │
└──────────────┴──────────────────────────────────┘
```

- `NavigationSplitView` (iOS/iPadOS/macOS universal).
- Левая колонка: `List` с `Label(displayName, systemImage: icon)`.
  Бейдж «● Изменён» если `isCustom == true`.
- Правая панель: `TextEditor` с моноширинным шрифтом (.monospaced).
- Bottom bar: статус + кнопка «Сбросить к стандартному».
- Автосохранение через debounce 1 сек после последнего нажатия клавиши.

### Интеграция с AI-модулем

`Classifier` / `Summarizer` / etc. — вместо хардкода промпта:
```swift
// Было (ClassifyV1.swift):
let systemPrompt = "Ты — ассистент почты..."

// Стало:
let systemPrompt = try await promptStore.load("classify")
```

`PromptStore` инжектится в каждый AI-сервис через init.
При отсутствии PromptStore (backward compat) — fallback на bundled.

## Cost estimation (per 100 писем)

| Фича | Токенов в | Токенов из | Cost (DeepSeek) |
|---|---|---|---|
| P: Prompt Editor | 0 | 0 | $0 (UI only) |
| A: Summary | ~800 | ~150 | $0.001 |
| B: Quick Reply | ~400 | ~200 | $0.001 |
| C: Snippet | ~200 | ~30 | $0.0003 |
| E: Bulk-delete | ~2000 | ~300 | $0.003 |
| G: Translate | ~2000 | ~2000 | $0.005 |
| H: Actions | ~400 | ~150 | $0.001 |
| I: Categories | +20 | +10 | $0.0002 |
| J: Snooze | ~300 | ~50 | $0.0005 |
| K: Profiles | 0 | 0 | $0 (local) |
