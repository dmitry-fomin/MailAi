# Predefined AI Prompts

Date: 2026-04-28

## Overview

Заменить однострочные заглушки в `Packages/AI/Sources/AI/Prompts/*.md` настоящими промптами. Добавить централизованную инициализацию: при первом запуске приложения все `.md`-файлы копируются из бандла в `~/.mailai/prompts/`, если их там ещё нет. Пользователь может редактировать файлы напрямую. JSON-схемы ответов остаются в Swift-коде рядом с парсерами.

---

## Architecture

### PromptStore.initializeDefaults()

Новый метод актора `PromptStore`. Вызывается один раз при старте AppShell (в `ApplicationDelegate` или эквиваленте).

```swift
public func initializeDefaults() async throws
```

Логика:
1. Создаёт `~/.mailai/prompts/` если не существует.
2. Итерирует по `PromptEntry.allEntries`.
3. Для каждого `entry.id` проверяет наличие `~/.mailai/prompts/{id}.md`.
4. Если файл отсутствует — копирует из бандла (`Bundle.module`).
5. Если файл существует — ничего не делает.

### PromptStore.reset(id:)

Текущая реализация удаляет файл и при следующем `load` падает с `.notFound`. Исправляем: `reset` перезаписывает файл из бандла (не удаляет).

### Акторы

Каждый актор (ThreadSummarizer, ActionExtractor и все новые) при инициализации или первом вызове загружает инструкцию:

```swift
let template = try await PromptStore.shared.load(id: "summarize")
let instruction = template
    .replacingOccurrences(of: "{{THREAD}}", with: threadText)
    // ... остальные плейсхолдеры
let systemPrompt = instruction + "\n\n" + Self.responseFormat
```

Плейсхолдеры (`{{FROM}}`, `{{SUBJECT}}`, `{{THREAD}}` и т.д.) заменяются актором перед отправкой. Пользовательское сообщение (`user:`) остаётся пустым или содержит дополнительный контекст по усмотрению актора.

`responseFormat` — `private static let`, хардкод рядом с парсером.

---

## Prompt Files (instruction-only, no JSON schema)

### classify.md
```
You are an email importance classifier. Analyze the email and determine whether it requires the user's attention.

From: {{FROM}}
Subject: {{SUBJECT}}
Preview: {{SNIPPET}}

Consider:
- Direct questions or action requests addressed to the user
- Time-sensitive content (deadlines, meetings, urgent issues)
- Emails from known contacts vs. automated senders
- Marketing, newsletters, and automated notifications are typically unimportant
```

### summarize.md
```
You are an email thread summarizer. Analyze the following email thread and produce a concise summary.

{{THREAD}}

Focus on:
- The main topic and outcome of the conversation
- Key decisions made
- Open questions or unresolved issues
- All participants involved
```

### extract_actions.md
```
You are an action item extractor. Read the email body and identify all tasks, deadlines, meetings, questions, and important links.

{{BODY}}

Extract only concrete, actionable items — skip pleasantries and generic phrases.
```

### quick_reply.md
```
You are an email reply assistant. Suggest three brief reply options for this email.

From: {{FROM}}
Subject: {{SUBJECT}}
Message: {{BODY}}

Each reply should be professional and concise (1–2 sentences). Offer distinct intents: accept, decline, ask for clarification.
```

### bulk_delete.md
```
You are an email cleanup advisor. Analyze the following emails and identify which ones can be safely deleted.

{{MESSAGES}}

Mark for deletion: marketing, automated notifications, resolved threads, unread newsletters.
Never mark: pending action items, receipts, emails from real people awaiting a response.
```

### translate.md
```
You are an email translator. Translate the following email into {{TARGET_LANGUAGE}}.

{{BODY}}

Preserve the original tone and formatting. Do not add explanations or commentary.
```

### categorize.md
```
You are an email categorizer. Classify the email by category, detect its language, and assess its tone.

From: {{FROM}}
Subject: {{SUBJECT}}
Preview: {{SNIPPET}}

Category examples: newsletter, receipt, notification, work, personal, social, travel, finance, support.
Tone examples: formal, casual, urgent, friendly, automated.
```

### snooze.md
```
You are a smart email scheduler. Suggest the best time to follow up or revisit this message.

From: {{FROM}}
Subject: {{SUBJECT}}
Received: {{DATE}}
Message: {{BODY}}

Consider explicit dates mentioned, typical response windows, and the urgency of the request.
```

### snippet.md
```
You are an email preview generator. Create a single-line AI preview that captures the email's essence — beyond just the first sentence.

From: {{FROM}}
Subject: {{SUBJECT}}
Body: {{BODY}}

The snippet must be under 120 characters, informative, and scannable.
```

### draft_coach.md
```
You are a professional writing coach. Review this email draft and suggest improvements.

Subject: {{SUBJECT}}
Draft: {{DRAFT}}

Evaluate: clarity, conciseness, professional tone, call to action, grammar.
Provide specific, actionable suggestions.
```

### nl_search.md
```
You are an email search assistant. Convert the user's natural language query into structured search parameters.

Query: {{QUERY}}

Extract only fields explicitly or implicitly mentioned: sender, recipient, date range, keywords, subject keywords, has attachment, label.
```

### follow_up.md
```
You are an email follow-up analyzer. Determine whether this email requires a follow-up and suggest when.

From: {{FROM}}
Subject: {{SUBJECT}}
Sent: {{DATE}}
Message: {{BODY}}

Consider: unanswered questions, pending decisions, explicit requests for response, time elapsed.
```

### attachment_summary.md
```
You are an attachment summarizer. Summarize the content of the following file.

Filename: {{FILENAME}}
Content:
{{CONTENT}}

Provide a concise summary: purpose, key points, action items, important figures.
```

### meeting_parser.md
```
You are a meeting details extractor. Parse the email and extract all meeting-related information.

Subject: {{SUBJECT}}
Message: {{BODY}}

Extract only fields explicitly mentioned: title, date, time, timezone, duration, location, organizer, attendees, agenda, dial-in details.
```

---

## JSON Response Formats (stay in Swift)

| Prompt ID | Response schema |
|-----------|----------------|
| classify | `{"importance": "important\|unimportant\|newsletter", "reason": "..."}` |
| summarize | `{"summary": "...", "participants": [...], "keyPoints": [...]}` |
| extract_actions | `[{"kind": "deadline\|task\|meeting\|link\|question", "text": "...", "dueDate": "ISO8601\|null"}]` |
| quick_reply | `{"replies": [{"tone": "accept\|decline\|clarify", "text": "..."}]}` |
| bulk_delete | `[{"messageId": "...", "reason": "..."}]` |
| translate | `{"translation": "...", "detectedLanguage": "..."}` |
| categorize | `{"category": "...", "language": "...", "tone": "..."}` |
| snooze | `{"suggestAt": "ISO8601", "reason": "..."}` |
| snippet | `{"snippet": "..."}` |
| draft_coach | `{"suggestions": [{"field": "tone\|clarity\|cta\|grammar", "comment": "...", "suggestion": "..."}]}` |
| nl_search | `{"from": "...", "to": "...", "after": "ISO8601\|null", "before": "ISO8601\|null", "keywords": [...], "subject": "...", "hasAttachment": bool\|null, "label": "..."}` |
| follow_up | `{"needsFollowUp": bool, "suggestAt": "ISO8601\|null", "reason": "..."}` |
| attachment_summary | `{"summary": "...", "keyPoints": [...], "actionItems": [...]}` |
| meeting_parser | `{"title": "...", "date": "ISO8601\|null", "timezone": "...", "duration": "...", "location": "...", "organizer": "...", "attendees": [...], "agenda": [...], "dialIn": "..."}` |

---

## Affected Files

- `Packages/AI/Sources/AI/PromptStore.swift` — добавить `initializeDefaults()`, исправить `reset(id:)`
- `Packages/AI/Sources/AI/Prompts/*.md` — обновить все 14 файлов
- `Packages/AI/Sources/AI/ThreadSummarizer.swift` — убрать хардкод, загружать из PromptStore
- `Packages/AI/Sources/AI/ActionExtractor.swift` — убрать хардкод, загружать из PromptStore
- AppShell entry point — вызов `PromptStore.shared.initializeDefaults()`

## Out of Scope

- UI для редактирования промптов внутри приложения
- Версионирование промптов / миграции при обновлении бандла
- Новые Swift-акторы для prompt-типов без реализации (bulk_delete, translate, и др.) — только промпты и схемы
