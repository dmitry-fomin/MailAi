# План реализации MVP

Соответствует [SPECIFICATION.md](SPECIFICATION.md). Принципы из [CONSTITUTION.md](CONSTITUTION.md) обязательны к исполнению.

## Обзор

Параллельная двухпоточная разработка:

- **Поток A (UI-first на моках)** — собираем весь 3-колоночный layout на in-memory mock-данных. Цель — красивый UI, многооконность, state restoration, темы — без единого сетевого вызова.
- **Поток B (транспорт + хранилище)** — в отдельной git-ветке пишем собственный IMAP-клиент на SwiftNIO и GRDB-хранилище метаданных. Цель — CLI-smoke, покрытый тестами.
- **Интеграция** — мёрж двух потоков: мок-провайдер данных подменяется на реальный `MailTransport` + `MetadataStore`.

Каждый поток самодостаточен: UI работает без транспорта, транспорт проверяется CLI-смоуками без UI.

## Технические решения

### Стек

- **Swift 6**, minimum deployment — **macOS 14** (SwiftUI NavigationSplitView + `@Observable`).
- **SwiftUI** для всех новых views. **AppKit** через `NSViewRepresentable` для:
  - `NSTableView`-списка писем (виртуализация 100k+),
  - `NSStatusItem` (следующая фича, не в MVP).
- **Swift Strict Concurrency** — уровень `complete` в каждом SPM-пакете.
- **SwiftNIO** — IMAP-транспорт (NIO + NIOSSL + NIOExtras).
- **GRDB** — локальные метаданные. Если упрёмся в overhead — план B: `SQLite3` напрямую.
- **Swift Testing** (`import Testing`) — юнит-тесты.

### Структура репозитория

```
MailAi/
  MailAi.xcodeproj                  # app target
  MailAi/                           # SwiftUI entry, @main, bootstrap
  Packages/
    Core/                           # модели, протоколы, ошибки
    Secrets/                        # Keychain
    Storage/                        # GRDB, метаданные
    MailTransport/                  # IMAP через SwiftNIO
    AI/                             # OpenRouter (заглушка на MVP)
    UI/                             # переиспользуемые компоненты
    AppShell/                       # composition root, многооконность
    MockData/                       # фикстуры для dev-режима
  Tests/
  docs/
  agents/
```

Каждый Package — отдельный `Package.swift` с явным `public` API. Кросс-зависимости только в направлении вниз (Core ← Storage ← MailTransport ← AppShell), циклы запрещены.

### Ветки

- `main` — стабильная, куда мёржим оба потока.
- `feature/ui-mock` — Поток A.
- `feature/imap-transport` — Поток B.
- После merge-интеграции — возврат на `main`.

### Data Provider Abstraction

Ключевой трюк параллельной разработки — общий протокол `AccountDataProvider` в `Core`:

```swift
public protocol AccountDataProvider: Sendable {
    func mailboxes() async throws -> [Mailbox]
    func messages(in: Mailbox.ID, page: Page) -> AsyncStream<[Message]>
    func body(for: Message.ID) -> AsyncThrowingStream<ByteChunk, Error>
}
```

- Поток A пишет UI против `MockAccountDataProvider` (в `MockData`).
- Поток B пишет `LiveAccountDataProvider` (композиция `MailTransport` + `MetadataStore`).
- На интеграции `AppShell` переключает реализацию по feature-flag.

## Компоненты

### Поток A (UI + моки)

| Файл/модуль | Назначение |
|---|---|
| `Core/Models/*.swift` | `Account`, `Mailbox`, `Message`, `MessageBody`, `Thread`, `Attachment`, `Importance`, `MailError` |
| `Core/Protocols/AccountDataProvider.swift` | Абстракция провайдера данных |
| `MockData/MockAccountDataProvider.swift` | 200 писем, 3 папки, 2 треда, работает без сети |
| `MockData/Fixtures/*.json` | Датасет для моков |
| `UI/Components/MessageRowView.swift` | Строка письма в списке |
| `UI/Components/MailboxRowView.swift` | Строка папки в sidebar |
| `UI/Components/ReaderHeaderView.swift` | Header письма (аватар, from/to, дата) |
| `UI/Components/ReaderBodyView.swift` | Тело письма (plain/HTML без внешних ресурсов) |
| `UI/Components/ToolbarButtons.swift` | Toolbar reader'а (иконки — функции — заглушки) |
| `UI/Components/EmptyStateView.swift` | Пустые состояния |
| `AppShell/Scenes/AccountWindowScene.swift` | Окно-аккаунт, `NavigationSplitView` |
| `AppShell/Scenes/WelcomeWindow.swift` | Стартовое окно |
| `AppShell/ViewModels/AccountSessionModel.swift` | State окна (выбранный mailbox, список, открытое письмо) |
| `AppShell/Routing/WindowRouter.swift` | Открытие/фокусировка окон аккаунтов |
| `AppShell/Restoration/*.swift` | State restoration набора окон |
| `MailAi/MailAiApp.swift` | `@main`, сборка DI-графа |

### Поток B (транспорт + хранилище)

| Файл/модуль | Назначение |
|---|---|
| `Secrets/KeychainService.swift` | Keychain API, actor |
| `Storage/Schema.swift` | Таблицы, индексы, FTS5 |
| `Storage/Migrator.swift` | GRDB `DatabaseMigrator` |
| `Storage/MetadataStore.swift` | Actor, upsert/query/observe |
| `Storage/Tests/MigrationTests.swift` | Fixture → миграция → проверка схемы |
| `MailTransport/IMAP/NIOIMAPClient.swift` | SwiftNIO channel, TLS, IDLE |
| `MailTransport/IMAP/Commands.swift` | LOGIN, LIST, SELECT, FETCH, UID STORE, EXPUNGE |
| `MailTransport/IMAP/ResponseParser.swift` | Парсер ответов (ENVELOPE, BODYSTRUCTURE, FLAGS) |
| `MailTransport/MIME/Parser.swift` | Стриминговый MIME-парсер |
| `MailTransport/Encodings.swift` | RFC 2047, charset detection |
| `MailTransport/LiveAccountDataProvider.swift` | Объединяет Transport + Store в провайдера |
| `Tools/IMAPSmokeCLI/main.swift` | CLI: подключиться, вытащить 10 заголовков, залить в БД |
| `MailTransport/Tests/Fixtures/*.eml` | Корпус реальных писем для парсера |

## Зависимости

- **SwiftNIO** (`swift-nio`, `swift-nio-ssl`, `swift-nio-extras`) — транспорт.
- **GRDB** (`GRDB.swift`) — SQLite-обёртка.
- **swift-log** — структурированное логирование (whitelist полей).
- **SwiftLint** — через SPM-plugin или отдельный бинарь.
- **OpenRouter API** — не в MVP, интерфейс-заглушка в `AI`.

Весь остальной UI и инфраструктура — только Apple-фреймворки.

## Порядок реализации

### Фаза 0: Bootstrap (совместная, 1–2 дня)

1. Создать Xcode app target `MailAi` (macOS 14+, SwiftUI lifecycle).
2. Создать скелеты SPM-пакетов (`Package.swift` каждого) с пустыми `public` API.
3. Подключить SwiftLint, настроить `.swiftlint.yml` (warnings = errors).
4. Включить Strict Concurrency во всех пакетах.
5. Настроить CI (GitHub Actions или локальный pre-commit): `xcodebuild build`, `xcodebuild test`, `swiftlint`.
6. Определить и закомитить `Core/Models/*.swift` и `Core/Protocols/AccountDataProvider.swift` — **общий контракт двух потоков**.
7. Создать ветки `feature/ui-mock` и `feature/imap-transport`.

### Фаза A (поток UI, ветка `feature/ui-mock`)

A1. Mock-провайдер: 200 писем, 3 папки, 2 треда, async/await API, без сети.
A2. SwiftUI-скелет: `MailAiApp`, `WelcomeWindow`, пустой `AccountWindowScene` c `NavigationSplitView`.
A3. Sidebar: секции «Избранное / Смарт-ящики / <account>», papki, счётчики.
A4. Список писем: `MessageRowView`, привязка к выбранной папке, виртуализация через `List` (переход на `NSTableView` — если заметна просадка, метрика — скролл 10k писем ≥ 60 fps).
A5. Reader: header + body (plain text из мока), toolbar с иконками (кнопки — no-op).
A6. Навигация клавиатурой: ↑/↓, ⌘1/⌘2, Space, ⌘R (noop), Tab.
A7. Многооконность: `openWindow` для «New Account Window…», picker аккаунтов, запрет двух окон на один аккаунт.
A8. State restoration: перезапуск открывает те же окна и выбранные папки (без содержимого).
A9. Light/Dark + Dynamic Type smoke-проверка.
A10. Скриншот-тест Dark/Light на ключевых экранах (без snapshot-библиотек — руками + CI-артефакт).

### Фаза B (поток транспорт, ветка `feature/imap-transport`)

B1. `Secrets/KeychainService` + тесты на in-memory fake.
B2. `Storage/Schema` + миграция v1, `MetadataStore` — upsert/query/observe. Тесты на реальной файловой SQLite во временной папке.
B3. SwiftNIO channel pipeline: TCP → TLS → IMAP line-framing. Подключение к `imap.gmail.com` / `imap.yandex.com` (app password) smoke-скриптом.
B4. IMAP-команды: LOGIN, CAPABILITY, LIST, SELECT. Вывод в stdout.
B5. Парсер ответов: ENVELOPE, FLAGS, UID, BODYSTRUCTURE. Корпус тестов на 20+ реальных ответах.
B6. FETCH headers (range UID), запись в `MetadataStore` через `LiveAccountDataProvider`.
B7. FETCH BODY[] стримом, `AsyncThrowingStream<ByteChunk>`; MIME-парсер с charset.
B8. IDLE для inbox notifications (для пост-MVP готовность), базовый reconnect с backoff.
B9. CLI `IMAPSmokeCLI`: подключение → листинг папок → 10 заголовков → 1 тело в stdout.
B10. Performance-тест: 1000 FETCH headers за ≤ 2 с (локальный тестовый IMAP через `dovecot` в Docker — опционально).

### Фаза C: Интеграция (3–5 дней)

C1. Мёрж `feature/ui-mock` в `main`.
C2. Мёрж `feature/imap-transport` в `main`. Конфликтов почти не должно — разные модули.
C3. `LiveAccountDataProvider` подключается в `AppShell` вместо mock. Feature-flag `MOCK_DATA=1` оставляет мок для dev.
C4. Onboarding: форма добавления IMAP-аккаунта, сохранение в Keychain + Storage, первый FETCH.
C5. Интеграционный тест: end-to-end «добавить аккаунт → открыть письмо → закрыть окно → память освободилась» (проверка через `XCTMemoryMetric` / ручной профайл в Instruments).
C6. Финальный прогон чек-листа из SPECIFICATION.md (критерии приёмки).

## Ключевые инварианты (проверяются в тестах)

- Ни один тест не должен проходить, если в `Storage` оказался сериализованный `MessageBody`.
- Ни один лог не содержит subject/from/to — отдельный тест грепает артефакты логов.
- `AccountDataProvider` абстрагирует моки от реала — смена реализации не меняет ни одной строки в UI.
- Закрытие окна аккаунта → все его `Task`-и отменены, соединения закрыты, `MessageBody` == nil.

## Риски и митигации

| Риск | Ранняя детекция | Митигация |
|---|---|---|
| SwiftNIO IMAP-парсер займёт больше времени, чем UI | В конце фазы B5 — если ≥ 7 дней, включаем план B | План B: `MailCore2` через Obj-C bridge как temporary transport, оставляем NIO-реализацию в работе |
| SwiftUI `List` тормозит | Измерить на фазе A4 | Подменить на `NSTableView` через `NSViewRepresentable` сразу, не ждать регрессии |
| Многооконность SwiftUI криво восстанавливается | Фаза A8 | Частично на AppKit: `NSWindow` restoration + SwiftUI content внутри |
| GRDB overhead при batch upsert | Фаза B6 | `DatabasePool` + транзакции по 500 строк, prepared statements |
| IMAP-серверы по-разному отвечают | Фаза B5 | Корпус тестов на разных серверах (Gmail, Yandex, Mail.ru, FastMail) |

## Definition of Done для MVP

- Все критерии приёмки из SPECIFICATION.md зелёные.
- `main` собирается без warnings, все тесты зелёные, SwiftLint 0 warnings.
- Есть работающий CLI-smoke для IMAP (`IMAPSmokeCLI`).
- Есть режим `--mock` для запуска приложения без аккаунтов.
- `docs/*.md` и `agents/*.md` обновлены, если реализация разошлась с планами модулей.
