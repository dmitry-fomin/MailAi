# Predefined AI Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить однострочные заглушки в Prompts/*.md настоящими шаблонами и добавить централизованную инициализацию, которая копирует их в ~/.mailai/prompts/ при первом запуске.

**Architecture:** Промпты хранятся в бандле (.md), при старте копируются в ~/.mailai/prompts/ если отсутствуют (PromptStore.initializeDefaults). Акторы загружают инструкцию из PromptStore и добавляют hardcoded responseFormat. Placeholder-ы {{FROM}} и т.д. — документационные метки; данные письма уходят в user-сообщение (поведение ThreadSummarizer/ActionExtractor не меняется).

**Tech Stack:** Swift 6, actors, async/await, XCTest, Bundle.module resources

---

## File Map

| Файл | Действие |
|------|---------|
| `Packages/AI/Sources/AI/Prompts/*.md` (14 файлов) | Обновить содержимое |
| `Packages/AI/Sources/AI/PromptStore.swift` | Добавить `initializeDefaults()`, исправить `reset(id:)` |
| `Packages/AI/Sources/AI/ThreadSummarizer.swift` | Загружать инструкцию из PromptStore, кешировать |
| `Packages/AI/Sources/AI/ActionExtractor.swift` | Загружать инструкцию из PromptStore, кешировать |
| `Packages/AI/Tests/AITests/PromptStoreTests.swift` | Создать, тесты для initializeDefaults + reset |
| `MailAi/MailAiApp.swift` | Вызвать `PromptStore.shared.initializeDefaults()` в AppDelegate |

---

## Task 1: Обновить содержимое 14 .md файлов

**Files:**
- Modify: `Packages/AI/Sources/AI/Prompts/classify.md`
- Modify: `Packages/AI/Sources/AI/Prompts/summarize.md`
- Modify: `Packages/AI/Sources/AI/Prompts/extract_actions.md`
- Modify: `Packages/AI/Sources/AI/Prompts/quick_reply.md`
- Modify: `Packages/AI/Sources/AI/Prompts/bulk_delete.md`
- Modify: `Packages/AI/Sources/AI/Prompts/translate.md`
- Modify: `Packages/AI/Sources/AI/Prompts/categorize.md`
- Modify: `Packages/AI/Sources/AI/Prompts/snooze.md`
- Modify: `Packages/AI/Sources/AI/Prompts/snippet.md`
- Modify: `Packages/AI/Sources/AI/Prompts/draft_coach.md`
- Modify: `Packages/AI/Sources/AI/Prompts/nl_search.md`
- Modify: `Packages/AI/Sources/AI/Prompts/follow_up.md`
- Modify: `Packages/AI/Sources/AI/Prompts/attachment_summary.md`
- Modify: `Packages/AI/Sources/AI/Prompts/meeting_parser.md`

- [ ] **Шаг 1: Записать classify.md**

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

- [ ] **Шаг 2: Записать summarize.md**

```
You are an email thread summarizer. Analyze the following email thread and produce a concise summary.

{{THREAD}}

Focus on:
- The main topic and outcome of the conversation
- Key decisions made
- Open questions or unresolved issues
- All participants involved
```

- [ ] **Шаг 3: Записать extract_actions.md**

```
You are an action item extractor. Read the email body and identify all tasks, deadlines, meetings, questions, and important links.

{{BODY}}

Extract only concrete, actionable items — skip pleasantries and generic phrases.
```

- [ ] **Шаг 4: Записать quick_reply.md**

```
You are an email reply assistant. Suggest three brief reply options for this email.

From: {{FROM}}
Subject: {{SUBJECT}}
Message: {{BODY}}

Each reply should be professional and concise (1–2 sentences). Offer distinct intents: accept, decline, ask for clarification.
```

- [ ] **Шаг 5: Записать bulk_delete.md**

```
You are an email cleanup advisor. Analyze the following emails and identify which ones can be safely deleted.

{{MESSAGES}}

Mark for deletion: marketing, automated notifications, resolved threads, unread newsletters.
Never mark: pending action items, receipts, emails from real people awaiting a response.
```

- [ ] **Шаг 6: Записать translate.md**

```
You are an email translator. Translate the following email into {{TARGET_LANGUAGE}}.

{{BODY}}

Preserve the original tone and formatting. Do not add explanations or commentary.
```

- [ ] **Шаг 7: Записать categorize.md**

```
You are an email categorizer. Classify the email by category, detect its language, and assess its tone.

From: {{FROM}}
Subject: {{SUBJECT}}
Preview: {{SNIPPET}}

Category examples: newsletter, receipt, notification, work, personal, social, travel, finance, support.
Tone examples: formal, casual, urgent, friendly, automated.
```

- [ ] **Шаг 8: Записать snooze.md**

```
You are a smart email scheduler. Suggest the best time to follow up or revisit this message.

From: {{FROM}}
Subject: {{SUBJECT}}
Received: {{DATE}}
Message: {{BODY}}

Consider explicit dates mentioned, typical response windows, and the urgency of the request.
```

- [ ] **Шаг 9: Записать snippet.md**

```
You are an email preview generator. Create a single-line AI preview that captures the email's essence — beyond just the first sentence.

From: {{FROM}}
Subject: {{SUBJECT}}
Body: {{BODY}}

The snippet must be under 120 characters, informative, and scannable.
```

- [ ] **Шаг 10: Записать draft_coach.md**

```
You are a professional writing coach. Review this email draft and suggest improvements.

Subject: {{SUBJECT}}
Draft: {{DRAFT}}

Evaluate: clarity, conciseness, professional tone, call to action, grammar.
Provide specific, actionable suggestions.
```

- [ ] **Шаг 11: Записать nl_search.md**

```
You are an email search assistant. Convert the user's natural language query into structured search parameters.

Query: {{QUERY}}

Extract only fields explicitly or implicitly mentioned: sender, recipient, date range, keywords, subject keywords, has attachment, label.
```

- [ ] **Шаг 12: Записать follow_up.md**

```
You are an email follow-up analyzer. Determine whether this email requires a follow-up and suggest when.

From: {{FROM}}
Subject: {{SUBJECT}}
Sent: {{DATE}}
Message: {{BODY}}

Consider: unanswered questions, pending decisions, explicit requests for response, time elapsed.
```

- [ ] **Шаг 13: Записать attachment_summary.md**

```
You are an attachment summarizer. Summarize the content of the following file.

Filename: {{FILENAME}}
Content:
{{CONTENT}}

Provide a concise summary: purpose, key points, action items, important figures.
```

- [ ] **Шаг 14: Записать meeting_parser.md**

```
You are a meeting details extractor. Parse the email and extract all meeting-related information.

Subject: {{SUBJECT}}
Message: {{BODY}}

Extract only fields explicitly mentioned: title, date, time, timezone, duration, location, organizer, attendees, agenda, dial-in details.
```

- [ ] **Шаг 15: Коммит**

```bash
git add Packages/AI/Sources/AI/Prompts/
git commit -m "feat(ai): заполнить 14 .md-шаблонов промптов"
```

---

## Task 2: PromptStore — initializeDefaults() + fix reset()

**Files:**
- Modify: `Packages/AI/Sources/AI/PromptStore.swift`
- Create: `Packages/AI/Tests/AITests/PromptStoreTests.swift`

- [ ] **Шаг 1: Создать тестовый файл с падающими тестами**

Создать `Packages/AI/Tests/AITests/PromptStoreTests.swift`:

```swift
#if canImport(XCTest)
import XCTest
@testable import AI

final class PromptStoreTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func testInitializeDefaultsCreatesAllFiles() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()

        for entry in PromptEntry.allEntries {
            let file = tmp.appendingPathComponent("\(entry.id).md")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "\(entry.id).md should exist after initializeDefaults"
            )
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(content.isEmpty, "\(entry.id).md should not be empty")
        }
    }

    func testInitializeDefaultsDoesNotOverwriteExistingFile() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let customContent = "custom user override"
        let file = tmp.appendingPathComponent("summarize.md")
        try customContent.write(to: file, atomically: true, encoding: .utf8)

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()

        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content, customContent,
            "initializeDefaults must not overwrite existing user file")
    }

    func testInitializeDefaultsIdempotent() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()
        try await store.initializeDefaults() // second call must not throw

        let file = tmp.appendingPathComponent("summarize.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testResetRestoresBundleContent() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()

        let file = tmp.appendingPathComponent("summarize.md")
        let bundleContent = try String(contentsOf: file, encoding: .utf8)

        try "custom override".write(to: file, atomically: true, encoding: .utf8)
        try await store.reset(id: "summarize")

        let restored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(restored, bundleContent,
            "reset must restore bundled default content")
    }

    func testResetCreatesFileIfMissing() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        // Do NOT call initializeDefaults — file doesn't exist yet
        try await store.reset(id: "summarize")

        let file = tmp.appendingPathComponent("summarize.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
```

- [ ] **Шаг 2: Убедиться что тесты падают**

```bash
cd Packages/AI && swift test --filter PromptStoreTests 2>&1 | tail -20
```

Ожидаемый результат: ошибка компиляции или FAIL — `initializeDefaults()` не существует.

- [ ] **Шаг 3: Реализовать initializeDefaults() и исправить reset(id:) в PromptStore.swift**

Заменить текущий `reset(id:)` и добавить `initializeDefaults()`:

```swift
/// Copies all bundled prompts to userPromptsDir if they don't already exist.
/// Safe to call multiple times — skips existing files.
public func initializeDefaults() async throws {
    let dir = userPromptsDir
    try await Task.detached(priority: .utility) {
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        for entry in PromptEntry.allEntries {
            let dest = dir.appendingPathComponent("\(entry.id).md")
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            guard let src = Bundle.module.url(
                forResource: entry.id,
                withExtension: "md",
                subdirectory: "Prompts"
            ) else {
                throw PromptStoreError.notFound(entry.id)
            }
            try FileManager.default.copyItem(at: src, to: dest)
        }
    }.value
}

/// Restores the user override file from the bundled default.
/// Creates the file if it doesn't exist in userPromptsDir.
public func reset(id: String) async throws {
    let dir = userPromptsDir
    try await Task.detached(priority: .utility) {
        guard let src = Bundle.module.url(
            forResource: id,
            withExtension: "md",
            subdirectory: "Prompts"
        ) else {
            throw PromptStoreError.notFound(id)
        }
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let dest = dir.appendingPathComponent("\(id).md")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
    }.value
}
```

- [ ] **Шаг 4: Прогнать тесты**

```bash
cd Packages/AI && swift test --filter PromptStoreTests 2>&1 | tail -20
```

Ожидаемый результат: все тесты PASS.

- [ ] **Шаг 5: Коммит**

```bash
git add Packages/AI/Sources/AI/PromptStore.swift \
        Packages/AI/Tests/AITests/PromptStoreTests.swift
git commit -m "feat(ai): PromptStore.initializeDefaults() + fix reset(id:)"
```

---

## Task 3: ThreadSummarizer — загрузка инструкции из PromptStore

**Files:**
- Modify: `Packages/AI/Sources/AI/ThreadSummarizer.swift`

ThreadSummarizer уже строит user-сообщение через `buildUserPrompt`. System-промпт меняем: убираем хардкод, загружаем инструкцию из PromptStore и кешируем. responseFormat остаётся статичным в Swift.

- [ ] **Шаг 1: Обновить ThreadSummarizer.swift**

Полное новое содержимое файла:

```swift
import Foundation
import Core

public actor ThreadSummarizer: AISummarizer {
    private let provider: any AIProvider
    private var cachedSystemPrompt: String?

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    public func summarize(
        inputs: [MessageSummaryInput]
    ) -> AsyncThrowingStream<String, any Error> {
        let capped = Array(inputs.prefix(10))
        let userPrompt = buildUserPrompt(inputs: capped)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let system = try await self.resolveSystemPrompt()
                    for try await chunk in self.provider.complete(
                        system: system,
                        user: userPrompt,
                        streaming: true,
                        maxTokens: 512
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func resolveSystemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }
        let instruction = try await PromptStore.shared.load(id: "summarize")
        let full = instruction + "\n\n" + Self.responseFormat
        cachedSystemPrompt = full
        return full
    }

    private static let responseFormat = """
        Respond only with valid JSON, no markdown, no explanation:
        {"summary": "2-3 sentence summary of the thread", "participants": ["address1", "address2"], "keyPoints": ["point 1", "point 2"]}
        """

    private func buildUserPrompt(inputs: [MessageSummaryInput]) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        return inputs.enumerated().map { (i, input) in
            """
            Message \(i + 1):
            From: \(input.from)
            Date: \(dateFormatter.string(from: input.date))
            Body: \(input.bodySnippet)
            """
        }.joined(separator: "\n\n")
    }
}
```

- [ ] **Шаг 2: Сбилдить пакет**

```bash
cd Packages/AI && swift build 2>&1 | tail -20
```

Ожидаемый результат: Build complete.

- [ ] **Шаг 3: Коммит**

```bash
git add Packages/AI/Sources/AI/ThreadSummarizer.swift
git commit -m "refactor(ai): ThreadSummarizer загружает инструкцию из PromptStore"
```

---

## Task 4: ActionExtractor — загрузка инструкции из PromptStore

**Files:**
- Modify: `Packages/AI/Sources/AI/ActionExtractor.swift`

Тот же паттерн: убрать хардкод systemPrompt, загрузить из PromptStore, responseFormat оставить в Swift.

- [ ] **Шаг 1: Обновить ActionExtractor.swift**

Полное новое содержимое файла:

```swift
import Foundation
import Core

public actor ActionExtractor: AIActionExtractor {
    private let provider: any AIProvider
    private var cachedSystemPrompt: String?

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    public func extract(body: String) async throws -> [ActionItem] {
        let snippet = String(body.prefix(2000))
        let system = try await resolveSystemPrompt()
        var fullResponse = ""
        for try await chunk in provider.complete(
            system: system,
            user: snippet,
            streaming: false,
            maxTokens: 600
        ) {
            fullResponse += chunk
        }
        return try parseResponse(fullResponse)
    }

    // MARK: - Private

    private func resolveSystemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }
        let instruction = try await PromptStore.shared.load(id: "extract_actions")
        let full = instruction + "\n\n" + Self.responseFormat
        cachedSystemPrompt = full
        return full
    }

    private static let responseFormat = """
        Respond only with valid JSON array, no markdown, no explanation:
        [{"kind": "deadline|task|meeting|link|question", "text": "description", "dueDate": "ISO8601 or null"}]
        Rules:
        - kind must be one of: deadline, task, meeting, link, question
        - dueDate: ISO8601 string if a date can be inferred, otherwise omit the field
        - Include only meaningful actions, not generic phrases
        """

    private func parseResponse(_ json: String) throws -> [ActionItem] {
        let cleaned = stripMarkdown(json)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode([RawItem].self, from: data)
        return decoded.compactMap { item in
            guard let kind = ActionKind(rawValue: item.kind) else { return nil }
            var dueDate: Date?
            if let dueDateStr = item.dueDate {
                dueDate = ISO8601DateFormatter().date(from: dueDateStr)
            }
            return ActionItem(
                id: UUID().uuidString,
                kind: kind,
                text: item.text,
                dueDate: dueDate
            )
        }
    }

    private func stripMarkdown(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            let lines = result.components(separatedBy: "\n")
            let inner = lines.dropFirst().dropLast()
            result = inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private struct RawItem: Decodable {
        let kind: String
        let text: String
        let dueDate: String?
    }
}
```

- [ ] **Шаг 2: Сбилдить пакет**

```bash
cd Packages/AI && swift build 2>&1 | tail -20
```

Ожидаемый результат: Build complete.

- [ ] **Шаг 3: Прогнать все тесты AI**

```bash
cd Packages/AI && swift test 2>&1 | tail -20
```

Ожидаемый результат: все тесты PASS.

- [ ] **Шаг 4: Коммит**

```bash
git add Packages/AI/Sources/AI/ActionExtractor.swift
git commit -m "refactor(ai): ActionExtractor загружает инструкцию из PromptStore"
```

---

## Task 5: AppDelegate — вызов initializeDefaults() при старте

**Files:**
- Modify: `MailAi/MailAiApp.swift`

`AppDelegate.applicationDidFinishLaunching` — правильное место. Уже импортирует `AI`.

- [ ] **Шаг 1: Добавить вызов в AppDelegate**

В `MailAi/MailAiApp.swift` заменить:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.setupDelegate()
    }
}
```

на:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.setupDelegate()
        Task {
            try? await PromptStore.shared.initializeDefaults()
        }
    }
}
```

`try?` — сбой инициализации промптов не должен крашить приложение; при следующем `load()` сработает bundle-fallback.

- [ ] **Шаг 2: Сбилдить приложение**

```bash
xcodebuild -scheme MailAi -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:|Build succeeded|Build FAILED"
```

Ожидаемый результат: `Build succeeded`.

- [ ] **Шаг 3: Коммит**

```bash
git add MailAi/MailAiApp.swift
git commit -m "feat(app): вызывать PromptStore.initializeDefaults() при старте"
```

---

## Task 6: Push

- [ ] **Шаг 1: Итоговая проверка**

```bash
cd Packages/AI && swift test 2>&1 | tail -5
```

- [ ] **Шаг 2: Push**

```bash
git push
```
