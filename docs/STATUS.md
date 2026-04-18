# MailAi — текущее состояние проекта

Дата среза: 2026-04-18. Ветка: `main`.

## Что сделано (мерджнуто в main)

### Каркас и инфраструктура
- Монорепа на SwiftPM: 8 локальных пакетов в `Packages/`.
- Xcode app target `MailAi/` (SwiftUI entry), генерится через `xcodegen` из `project.yml`.
- macOS 14+, Swift 6, strict concurrency complete, warnings-as-errors.
- Smoke-тесты: executable-таргеты `*Smoke` + `Scripts/smoke.sh` (CLT-only окружение, XCTest гейтится `#if canImport(XCTest)`).
- CI: `.github/workflows/ci.yml`.
- Beads (`bd`) для трекинга задач, Dolt-хранилище в `.beads/`.

### Модули (на main)

| Модуль | Что есть |
|---|---|
| **Core** | Доменные модели (`Account`, `Mailbox`, `Message`, `MessageBody`, `Attachment`, `Thread`, `Importance`, `MailError`), протокол `AccountDataProvider`. |
| **Secrets** | `SecretsStore` поверх Security.framework (Keychain). |
| **Storage** | `MetadataStore` — заглушка интерфейса (без GRDB пока). |
| **MailTransport** | `LiveAccountDataProvider` — заглушка для будущего IMAP. |
| **AI** | `AIClassifier` — заглушка. |
| **MockData** | `MockAccountDataProvider` — фейковые аккаунты/папки/письма для UI. |
| **UI** | `UIPlaceholder` — пустой пакет под переиспользуемые компоненты. |
| **AppShell** | `MailAiApp`, `WelcomeScene`, `AccountWindowScene`, `AccountSessionModel`, `Sidebar/*` (item/provider/view/viewmodel). |

### UI (фазы A2 + A3)
- Welcome-окно и окно-аккаунт (`AccountWindowScene`).
- **Sidebar**: 4 секции — Избранное, Смарт-ящики, На моём Mac, `<account.email>`. Иконки SF Symbols, бейджи непрочитанных, выбор активной папки. `MockSidebarProvider` пока подаёт данные из `MockAccountDataProvider`.
- 11/11 unit-тестов на `SidebarViewModel`.

### Документация модулей
В `docs/` уже лежат заготовки: `Core.md`, `MailTransport.md`, `Storage.md`, `AI.md`, `Secrets.md`, `AppShell.md`, `UI.md`, `Search.md`, `Attachments.md`, `Notifications.md`, `StatusBar.md`. Подпапка `docs/libs/` — по внешним библиотекам (SwiftNIO, GRDB, Keychain, OpenRouter).

## Что есть локально, но НЕ в main

### Ветка `feature/imap-transport` (готова к мерджу — задача `MailAi-j8p`)
Содержит коммиты, которых нет в main:
- **B1**: `KeychainService` на Security.framework + smoke-тест.
- **WIP-коммит** `AI-pack каркас + IMAP-скелет + Storage GRDB`:
  - **AI**: `Classifier`, `ClassifyV1`, `OpenRouterClient`, `RuleEngine`, `SnippetExtractor` + 7 тест-файлов (включая интеграционные с OpenRouter).
  - **Storage**: `GRDBMetadataStore`, `RulesRepository`, `ClassificationLog`, `Schema`/`SchemaV2`, `RetentionGC`, `DatabasePathProvider` + тесты.
  - **AppShell**: `ClassificationCoordinator`, `ClassificationQueue`, `UndoStack` + тесты.
  - **MailTransport**: каркас IMAP — `IMAPClientBootstrap`, `IMAPConnection`, `IMAPFrameCodec`, `IMAPLine`, `IMAPResponse`, `IMAPTag` + loopback/TLS-тесты.
  - **Core**: `ClassificationInput`, `ClassificationResult`, `Rule`, `AuditEntry`, `AIProvider`.
- **B5**: `IMAPResponseParser` — парсер ENVELOPE / FLAGS / UID / BODYSTRUCTURE / INTERNALDATE / RFC822.SIZE, RFC 2047-декодер заголовков, `IMAPFetchResponse`. 30 тестов на корпусе Gmail/Yandex/Mail.ru/FastMail. Всего 57 passed / 1 skipped (live TLS) в `MailTransportTests`.

> **Внимание:** этот WIP-коммит склеил в одну точку три независимых направления (AI-pack, Storage, IMAP). Перед мерджем в main стоит распилить на отдельные коммиты или хотя бы провести явный merge-commit с описанием.

## Как собрать/посмотреть

```bash
# UI-просмотр
brew install xcodegen          # один раз
xcodegen generate              # из корня проекта
open MailAi.xcodeproj          # схема MailAi → ⌘R

# Unit-тесты пакета
swift test --package-path Packages/AppShell

# Smoke-проверка всех executable-таргетов
Scripts/smoke.sh
```

## Дорожная карта (что дальше)

Из `bd list --status=open` — 18 задач. Сгруппировано по приоритету для следующих шагов.

### Ближайшее (разблокировано прямо сейчас)
1. **MailAi-j8p — C2: merge `feature/imap-transport` → main.** Принести в main: B1 (Keychain), AI-pack, Storage (GRDB), IMAP-каркас + B5-парсер. Желательно разбить на 2-3 коммита.
2. **MailAi-loi — A4: список писем** (`MessageRowView`, виртуализация через `LazyVStack`/`Table`).
3. **MailAi-14v — A5: Reader** (header + body + toolbar для одного письма).
4. **MailAi-93n — B6: FETCH headers + запись в MetadataStore.** Связывает свежий B5-парсер со Storage.

### UI-фазы A
- **A6** (`MailAi-0g9`) — клавиатурная навигация (J/K/⌘↑↓, выделение, Delete).
- **A7** (`MailAi-p2w`) — многооконность: окно=аккаунт, picker аккаунта, запрет дублей окна.
- **A8** (`MailAi-vuf`) — state restoration набора окон между запусками.
- **A9** (`MailAi-3er`) — Light/Dark темы + Dynamic Type.
- **A10** (`MailAi-1xa`) — скриншот-тесты ключевых экранов в Dark/Light.

### Транспорт B (после мерджа `feature/imap-transport`)
- **B7** (`MailAi-7xe`) — FETCH BODY[] стримом + MIME-парсер (без хранения тела на диске).
- **B8** (`MailAi-8gg`) — IDLE + reconnect с экспоненциальным backoff.
- **B9** (`MailAi-39g`) — CLI `IMAPSmokeCLI` для ручной проверки серверов.
- **B10** (`MailAi-qyl`) — perf-тест: FETCH 1000 заголовков ≤ 2 с.

### Интеграция и онбординг C
- **C3** (`MailAi-f0h`) — подключить `LiveAccountDataProvider` в AppShell под feature-flag `MOCK_DATA` (сейчас всё на моках).
- **C4** (`MailAi-f62`) — UI-онбординг: форма добавления IMAP-аккаунта (host/port/login/пароль → Keychain).
- **C5** (`MailAi-lvi`) — end-to-end интеграционный тест + проверка профиля памяти (тела писем не оседают).
- **C6** (`MailAi-whw`) — финальный прогон критериев приёмки `SPECIFICATION.md`.

### AI-pack v1
- **MailAi-465** — UI-каркас AI-pack в v1: пустые «AI»-папки и слоты под классификацию (после мерджа AI-pack из `feature/imap-transport`).

### Что НЕ закрыто планом и стоит подумать
- Реальный `LiveAccountDataProvider` поверх IMAP (сейчас файл-заглушка) — должен появиться во время C3.
- Bulk-delete по AI-критерию (фича из README, отдельных задач в beads пока нет).
- Суммаризация переписок (тоже из README, задач нет).
- Notifications + StatusBar (документация есть в `docs/`, задач в beads — нет).
- Search (FTS5 + серверный) — `docs/Search.md` есть, задач нет.
- Attachments стриминг — `docs/Attachments.md` есть, задач нет.

> Эти пункты — кандидаты на новые `bd create` после фаз A/B/C.
