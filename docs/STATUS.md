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
- [x] **MailAi-8no** AI-3: `ClassificationQueue` (батчинг, ретраи, persistence в `classification_log`).
- [x] **MailAi-8te** AI-4: `RuleEngine` CRUD + сериализация в system prompt.
- [x] **MailAi-z96** AI-5: живые «Отфильтрованные» папки, `ClassificationProgressBar`, drag-to-rule (`RuleProposalSheet`).
- [x] **MailAi-new** AI-6: Settings → AI-pack (ключ через Keychain, модель из `OpenRouterModelCatalog`, CRUD правил, `aiPackEnabled`/`serverSyncEnabled`).
- [x] **MailAi-skb** AI-7: серверная синхронизация Important/Unimportant (`IMAPServerFolderSync`, `LiveAccountDataProvider.ensureServerFolders` + `moveAfterClassification`, `ClassificationCoordinator.postClassifyHook`).
- [x] **MailAi-4zm** AI-8: Retention GC + privacy-тесты.

### Пул IMAP-сессий
- [x] **MailAi-qrz** Pool-1: `IMAPSession` actor с command queue.
- [x] **MailAi-211** Pool-2: интеграция в `LiveAccountDataProvider`.
- [x] **MailAi-y23** Pool-3: IDLE-цикл для активной папки (`IMAPIdleController`, 29-мин таймер, `withTaskGroup`-гонка). Известный дефект — issue **Pool-3-fix** (зависание `stop()` на простаивающем канале).
- [x] **MailAi-md4** Pool-4: `SessionPoolIDLESmoke` (fake IMAP, EXISTS-push без ручного refresh, cancel-инвариант).

### SMTP / Compose
- [x] **MailAi-1qb** SMTP-1: SwiftNIO-клиент (EHLO/STARTTLS/AUTH/MAIL/RCPT/DATA).
- [x] **MailAi-2u7** SMTP-2: MIME-composer (RFC 2047).
- [x] **MailAi-h5m** SMTP-3: `SendProvider` + `LiveSendProvider` (actor) + `Kind.smtpPassword` с fallback на IMAP-пароль; SMTP-поля в `Account`.
- [x] **MailAi-91d** SMTP-4: черновики через IMAP APPEND.
- [x] **MailAi-tq4** SMTP-5: `ComposeScene` + `ComposeViewModel` + `ComposeWindowValue`; `⌘N` = новое письмо, `⌘⇧N` = новый аккаунт.
- [x] **MailAi-3e0** SMTP-6: `SMTPEndToEndSmoke` (FakeSMTPServer + FakeIMAPServer на NIO; happy / RCPT 550 / APPEND-fail).

### StatusBar / Notifications
- [x] **MailAi-faa** Status-1: `MenuBarExtra` со счётчиком и меню аккаунтов.
- [x] **MailAi-jgv** Status-2: `UNUserNotificationCenter` (privacy-aware).
- [x] **MailAi-v7r** Status-3: `StatusNotificationsSmoke` (контракт `badgeText` + чистая render-функция уведомлений без UN-фреймворка).

### Открытые follow-up
- **Pool-3-fix**: `IMAPIdleController.stop()` зависает на простаивающем канале (NIOAsyncChannel iterator не реагирует на `Task.cancel`).

## Как собрать/посмотреть

```bash
brew install xcodegen          # один раз
xcodegen generate              # из корня проекта
open MailAi.xcodeproj          # схема MailAi → ⌘R

swift test --package-path Packages/AppShell
Scripts/smoke.sh               # все executable *Smoke
```
