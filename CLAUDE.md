# MailAi

Нативный почтовый клиент для macOS с AI-анализом писем через OpenRouter. Помогает массово удалять почту по запросу, суммаризирует переписки, анализирует входящие. Тексты писем не хранятся на диске — только в памяти на время работы; расход памяти должен оставаться минимальным.

## Стек

- **Платформа**: macOS (минимальная версия — TODO: уточнить, ориентир macOS 14+)
- **Язык**: Swift (последняя стабильная версия)
- **UI**: SwiftUI + AppKit-интеропы там, где SwiftUI не покрывает (NSViewRepresentable)
- **Concurrency**: строго `async/await` + структурированная конкурентность, Swift Strict Concurrency включён
- **Почтовые протоколы**: IMAP, Exchange (EWS / Microsoft Graph — уточнить по ходу)
- **AI**: OpenRouter API (HTTP, без SDK)
- **Локальное хранилище**: SQLite или GRDB (решение по ходу) — **только метаданные/индексы**, тела писем никогда не пишутся на диск
- **Сборка**: Xcode + Swift Package Manager
- **Линтер**: SwiftLint

## Структура проекта

Greenfield — структура формируется. Целевой каркас (появится на следующих шагах):

- `MailAi/` — Xcode app target (SwiftUI entry, views, view models)
- `Packages/` — внутренние SPM-модули (Core, Mail, AI, Storage)
- `docs/` — документация модулей
- `agents/` — инструкции для AI-агентов по областям разработки
- `Tests/` — XCTest / Swift Testing

## Документация

- [docs/Core.md](docs/Core.md) — доменные модели, протоколы, ошибки
- [docs/MailTransport.md](docs/MailTransport.md) — IMAP, Exchange, отправка
- [docs/Storage.md](docs/Storage.md) — GRDB/SQLite, только метаданные
- [docs/AI.md](docs/AI.md) — OpenRouter, суммаризация, bulk-delete
- [docs/Secrets.md](docs/Secrets.md) — Keychain-обёртка
- [docs/AppShell.md](docs/AppShell.md) — многооконный шелл «окно = аккаунт»
- [docs/UI.md](docs/UI.md) — переиспользуемые SwiftUI-компоненты
- [docs/Search.md](docs/Search.md) — локальный FTS5 + серверный поиск
- [docs/Attachments.md](docs/Attachments.md) — стриминг и просмотр вложений
- [docs/Notifications.md](docs/Notifications.md) — системные уведомления с AI-фильтром
- [docs/StatusBar.md](docs/StatusBar.md) — иконка в menu bar со счётчиком и индикацией важности

### Библиотеки

- [docs/libs/swift-nio.md](docs/libs/swift-nio.md) — SwiftNIO + NIOSSL (IMAP-транспорт)
- [docs/libs/grdb.md](docs/libs/grdb.md) — GRDB.swift (миграции, observation, FTS5)
- [docs/libs/keychain.md](docs/libs/keychain.md) — Keychain Services (Security.framework)
- [docs/libs/openrouter.md](docs/libs/openrouter.md) — OpenRouter API (streaming, headers, модели)

## Агенты

- [agents/swift-core.md](agents/swift-core.md) — язык Swift, strict concurrency, ошибки
- [agents/swiftui-appkit.md](agents/swiftui-appkit.md) — UI-слой, AppKit-мосты
- [agents/mail-protocols.md](agents/mail-protocols.md) — IMAP, SMTP, Exchange/Graph
- [agents/database.md](agents/database.md) — GRDB/SQLite, миграции, FTS5
- [agents/ai-openrouter.md](agents/ai-openrouter.md) — OpenRouter API, промпты, приватность
- [agents/security-privacy.md](agents/security-privacy.md) — Keychain, sandbox, утечки
- [agents/testing.md](agents/testing.md) — Swift Testing, моки, конкурентность
- [agents/web-analytics.md](agents/web-analytics.md) — продуктовая аналитика (opt-in)
- [agents/pm-growth-architect.md](agents/pm-growth-architect.md) — scope, growth-петли, монетизация

## Правила

- **Память прежде всего**: тела писем держим в памяти только на время активной работы с ними; освобождаем сразу после использования. Стримим крупные тела, не загружаем целиком без нужды.
- **Никаких текстов писем на диске**: ни в кеше, ни в БД, ни в логах. В SQLite/GRDB — только метаданные (message-id, заголовки, флаги, размеры, хеши).
- **Безопасность секретов**: API-ключи (OpenRouter, пароли IMAP/Exchange) — только в Keychain. В код, логи и git они не попадают.
- **async/await**: запрещены completion-handlers в новом коде. Старые API оборачиваем в `withCheckedContinuation`.
- **Strict Concurrency**: актёры для изолированного состояния, `Sendable` для пересечений границ, `@MainActor` для UI.
- **Нет сторонним UI-библиотекам**: только SwiftUI + AppKit. Shimmer, popover-ы, таблицы — пишем сами.
- **Минимум зависимостей в целом**: каждая сторонняя зависимость требует обоснования.
- **SwiftLint**: сборка падает на warnings в CI.
- **Тесты**: критичная логика (парсинг писем, удаление, суммаризация) покрывается unit-тестами; сетевые адаптеры — через протоколы и моки.

## Запрещено

- Сохранять тела писем и их фрагменты в любом персистентном хранилище.
- Логировать содержимое писем, адреса получателей, API-ключи.
- Использовать completion handlers и DispatchQueue там, где возможно `async/await` / акторы.
- Добавлять сторонние UI-библиотеки (SnapKit, Alamofire-UI, любые alternative SwiftUI-компоненты).

## Build & Test

```bash
# TODO: после создания Xcode-проекта
# xcodebuild -scheme MailAi -destination 'platform=macOS' build
# xcodebuild -scheme MailAi test
# swiftlint
```

## Обновление

- Обновляй этот файл при значимых изменениях архитектуры.
- Обновляй `docs/*.md` при изменении логики модулей.
- Обновляй `agents/*.md` при изменении паттернов.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
