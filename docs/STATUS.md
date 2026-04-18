# MailAi — текущее состояние проекта

Дата среза: 2026-04-18. Ветка: `master` (main-ветка не используется; PR делаются напрямую в master).

## Что сделано (на master)

### Каркас и инфраструктура
- Монорепа на SwiftPM: локальные пакеты в `Packages/` (Core, Secrets, Storage, MailTransport, AI, MockData, UI, AppShell).
- Xcode app target `MailAi/` (SwiftUI entry), генерится через `xcodegen` из `project.yml`.
- macOS 14+, Swift 6, strict concurrency complete, warnings-as-errors.
- Smoke-тесты: executable-таргеты `*Smoke` + `Scripts/smoke.sh` (CLT-only окружение, XCTest гейтится `#if canImport(XCTest)`).
- CI: `.github/workflows/ci.yml`.
- Beads (`bd`) для трекинга задач, Dolt-хранилище в `.beads/`.

### Модули (на master)

| Модуль | Состав |
|---|---|
| **Core** | Модели (`Account`, `Mailbox`, `Message`, `MessageBody`, `Attachment`, `Thread`, `Importance`, `MailError`, `ClassificationInput/Result`, `Rule`, `AuditEntry`). Протоколы: `AccountDataProvider`, `MailActionsProvider`, `AIProvider`, `SearchService`. |
| **Secrets** | `KeychainService` (Security.framework) + `SecretsStore` (API для пароля IMAP и ключа OpenRouter, `Kind.imapPassword`/`Kind.openrouter`), `InMemorySecretsStore` для тестов. |
| **Storage** | `GRDBMetadataStore`, `Schema` v1/v2/**v3 (FTS5)**, `RulesRepository`, `ClassificationLog`, `RetentionGC`, `DatabasePathProvider`, `LocalSearcher` + `SearchQueryParser`, `GRDBSearchService`. |
| **MailTransport** | `IMAPClientBootstrap`, `IMAPConnection` (LOGIN/CAPABILITY/LIST/SELECT/FETCH/STORE/COPY/MOVE/EXPUNGE), `IMAPFrameCodec`, `IMAPResponseParser` (ENVELOPE/FLAGS/UID/BODYSTRUCTURE), MIME-стриминг BODY[]. `LiveAccountDataProvider` — реальный IMAP end-to-end. |
| **AI** | `OpenRouterClient` (URLSession streaming), `Classifier` actor + `ClassifyV1` промпт, `RuleEngine`, `SnippetExtractor`. |
| **MockData** | `MockAccountDataProvider` для UI-разработки и демо-режима. |
| **AppShell** | `MailAiApp`, сцены: Welcome / AccountWindow / AccountPicker / Onboarding / Settings. ViewModels: `AccountRegistry`, `AccountSessionModel` (+ `search`, `perform`), `OnboardingViewModel`, `SelectionPersistence`. `ClassificationCoordinator`, `ClassificationQueue`, `UndoStack`, Sidebar. |

### Фазы, доведённые до master

- **Каркас 0.1–0.7**, **UI A2–A10** (скриншот-тесты Light/Dark), **Transport B1–B10**, **Live 1–6** (реальный IMAP-провайдер), **Mail 1–4** (действия: delete/archive/flag/markRead + UI wiring + smoke), **Search 1–3** (FTS5 + парсер + UI-поиск), **AI 1–2** (OpenRouterClient + Classifier), **C1–C6** (merge веток, onboarding IMAP, интеграционный end-to-end + memory-инварианты, финальный прогон SPECIFICATION.md).

## Дорожная карта (19 открытых задач)

Источник: `bd list --status=open`. Ветка `feature/imap-transport` уже слита; main-ветка упразднена.

### AI-pack v1 (продолжение AI-1/2)
- **MailAi-8no** AI-3: `ClassificationQueue` (батчинг, ретраи, persistence в `classification_log`). *Ready.*
- **MailAi-8te** AI-4: `RuleEngine` CRUD + сериализация в system prompt.
- **MailAi-z96** AI-5: живые «Отфильтрованные» папки, прогресс-бар, drag-to-rule.
- **MailAi-new** AI-6: Settings → AI-pack (ключ, модель, правила).
- **MailAi-skb** AI-7: (опц.) серверная синхронизация «Отфильтрованных».
- **MailAi-4zm** AI-8: Retention GC + privacy-тесты.

### Пул IMAP-сессий
- **MailAi-qrz** Pool-1: `IMAPSession` actor с command queue. *Ready.*
- **MailAi-211** Pool-2: интеграция в `LiveAccountDataProvider`.
- **MailAi-y23** Pool-3: IDLE-цикл для активной папки.
- **MailAi-md4** Pool-4: smoke session pool + IDLE.

### SMTP / Compose
- **MailAi-1qb** SMTP-1: SwiftNIO-клиент (EHLO/STARTTLS/AUTH/MAIL/RCPT/DATA). *Ready.*
- **MailAi-2u7** SMTP-2: MIME-composer (RFC 2047).
- **MailAi-h5m** SMTP-3: `SendProvider` + `LiveSendProvider` + Keychain SMTP.
- **MailAi-91d** SMTP-4: черновики через IMAP APPEND.
- **MailAi-tq4** SMTP-5: `ComposeScene`.
- **MailAi-3e0** SMTP-6: smoke SMTP + Compose end-to-end.

### StatusBar / Notifications
- **MailAi-faa** Status-1: `MenuBarExtra` со счётчиком и меню аккаунтов. *Ready.*
- **MailAi-jgv** Status-2: `UNUserNotificationCenter` (privacy-aware).
- **MailAi-v7r** Status-3: smoke StatusBar/Notifications.

## Как собрать/посмотреть

```bash
brew install xcodegen          # один раз
xcodegen generate              # из корня проекта
open MailAi.xcodeproj          # схема MailAi → ⌘R

swift test --package-path Packages/AppShell
Scripts/smoke.sh               # все executable *Smoke
```
