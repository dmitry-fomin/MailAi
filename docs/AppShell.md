# Модуль: AppShell

<!-- Статус: план модуля. Код ещё не написан. -->

## Назначение

Корневой каркас приложения: entry point, многооконная архитектура («окно = аккаунт», по модели IDE-проектов), composition root (сборка зависимостей), lifecycle, навигация.

## Ключевые сущности

- `MailAiApp` — `@main`, SwiftUI `App`.
- `AccountWindowScene` — `WindowGroup`/`Window` для окна-аккаунта.
- `WelcomeWindow` — стартовое окно выбора/создания аккаунта (если ни одно не открыто).
- `AppEnvironment` — DI-контейнер: транспорт, store, AI, secrets, notifications.
- `AccountSession` — состояние одного окна: аккаунт, выбранный mailbox, список писем, открытое письмо.
- `Router` — навигация внутри окна (sidebar → list → reader).

## Бизнес-логика

- **Окно на аккаунт**: открытие нового аккаунта = новое окно. Закрытие окна = завершение сессии аккаунта (освобождение памяти, закрытие соединений).
- **Одно окно — один актёр** для `AccountSession`. Состояния окон не пересекаются.
- **File menu**: «New Window…» → выбор существующего аккаунта или добавление нового.
- **State restoration**: при перезапуске восстанавливаем набор открытых окон-аккаунтов (без содержимого писем).
- **Клавиатурная навигация (A6)**: `⌘1` фокус sidebar, `⌘2` фокус list, `↑/↓` двигают selection в списке (ряд подскраливается в видимую область), `Space` / `Shift+Space` — page down / up в reader (реализовано через `NSScrollView` в `UI.KeyboardScrollableReader`), `Tab` циклирует фокус sidebar → list → reader, `⌘R` — noop refresh (TODO интеграция в фазе B).

## ComposeScene (SMTP-5)

- **`ComposeScene`** (`@MainActor`, SwiftUI) — окно «Новое письмо»: поля
  To/Cc/Subject/Body, кнопки «Отправить» / «Сохранить черновик».
- **`ComposeViewModel`** (`@MainActor`, `ObservableObject`) — управляет
  состоянием формы и валидацией. Зависимости (send / saveDraft) — замыкания,
  получаются через `AccountDataProviderFactory.makeSendProvider` /
  `makeDraftSaver` (см. [MailTransport.md](MailTransport.md)).
- **`ComposeWindowValue`** (`Hashable`, `Codable`) — ключ `WindowGroup`,
  содержит `accountID` и `nonce`. Каждое нажатие ⌘N формирует новый nonce —
  это даёт независимые окна compose.
- **`WindowGroup`-сцены** (в `MailAiApp`):
  - `welcome` — первичное окно;
  - `onboarding` — добавление аккаунта;
  - `account` (`for: Account.ID.self`) — окно-аккаунт;
  - `compose` (`for: ComposeWindowValue.self`) — compose-окно (SMTP-5).
- **Команды (File menu)**:
  - `⌘N` — `ComposeCommands` → `openWindow("compose")` для активного аккаунта;
  - `⌘⇧N` — «New Account Window» (раньше висело на ⌘N, переехало под
    composer-shortcut Mail.app).
- Тело письма (`String body`) живёт только во `@StateObject`-инстансе
  `ComposeViewModel` и освобождается при закрытии окна.

## Drag-to-rule + ClassificationProgressBar (AI-5)

- В sidebar окна-аккаунта между списком стандартных папок и пользовательских
  есть «Отфильтрованные» («Важное» / «Неважно»). На их строках работает
  `.dropDestination(for: DraggableMessage.self)`. По дропу `SidebarView.onDropMessages`
  вызывает callback из `AccountWindowScene`, который открывает
  `RuleProposalSheet`.
- `ClassificationProgressBar` (UI-модуль) подключается под тулбаром окна,
  биндится к `ClassificationProgressViewModel` (`@MainActor`), который
  слушает события `ClassificationQueue` через AsyncStream. Контракт:
  пустая очередь → bar скрыт.

## API

Не экспортируется наружу (top-level модуль).

## Зависимости

- **От**: все остальные модули.
- **Кто зависит**: —.
