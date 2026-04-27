# Модуль: StatusBar

## Назначение

Иконка в системной строке меню macOS (MenuBarExtra) со счётчиком непрочитанных писем. Быстрый доступ к списку аккаунтов, кнопка «Написать» и «Настройки».

## Архитектура

### Компоненты

| Компонент | Расположение | Описание |
|-----------|-------------|----------|
| `StatusBarBadgeLabel` | `UI/StatusBarView.swift` | Иконка конверта с красным бейджем (SF Symbol `envelope` + Capsule) |
| `StatusBarMenuContent` | `UI/StatusBarView.swift` | Содержимое выпадающего меню |
| `StatusBarAccountItem` | `UI/StatusBarView.swift` | Лёгкая проекция аккаунта для меню (id, email, displayName, unreadCount) |
| `MenuBarExtra` scene | `MailAiApp.swift` | Сцена MenuBarExtra в теле App |

### Данные

- **Бейдж**: общее количество непрочитанных (`AccountRegistry.totalUnreadCount`), агрегируется из `mailboxes[].unreadCount` всех активных сессий. При >99 показывается `99+`.
- **Меню**: список аккаунтов из `AccountRegistry.accounts` с их непрочитанными.
- **Реактивность**: `AccountRegistry` подписан на `objectWillChange` каждой `AccountSessionModel` — бейдж обновляется при загрузке мэйлбоксов и изменении флагов.

### Подсчёт непрочитанных

Подсчёт идёт по серверному `Mailbox.unreadCount`, а не по локальным `Message.flags`. Это даёт более точные данные (IMAP-сервер хранит счётчики отдельно) и не требует загрузки всех писем.

```
AccountRegistry.totalUnreadCount
  └── sessions.values.reduce(0) { session.mailboxes.reduce(0) { $0 + $1.unreadCount } }
```

Для аккаунтов без активной сессии (окно не открыто) — счётчик = 0. Фоновый подсчёт (AggregateCounter) появится в следующей фазе.

## Меню

```
┌──────────────────────────────┐
│  user@example.com          5 │  ← аккаунт (displayName || email) + count
│  work@corp.com             2 │
│  ─────────────────────────── │
│  Написать          ⌘⇧N      │  ← открывает welcome-окно (placeholder)
│  Настройки…                  │  ← SettingsLink → Settings scene
└──────────────────────────────┘
```

## Приватность

- Бейдж показывает **только количество** — без отправителя, темы или превью.
- Меню показывает email/имя аккаунта и счётчик — без содержимого писем.
- Никакие данные не покидают приложение.

## Зависимости

- **UI** → `Core` (Account.ID)
- **MailAiApp** → `UI` (StatusBarBadgeLabel, StatusBarMenuContent)
- **AccountRegistry** → Combine (каскад objectWillChange)

## Контракт `StatusBarBadgeLabel.badgeText` (Status-3)

Чистая функция от `unreadCount: Int → String`:

| `unreadCount` | `badgeText` |
|---|---|
| `≤ 0` | `""` (бейдж скрыт) |
| `1…99` | `"\(count)"` |
| `≥ 100` | `"99+"` |

Логика покрыта executable-смоком `StatusNotificationsSmoke` (`Packages/UI`) —
он не зависит от XCTest и не открывает AppKit. См. `docs/Notifications.md`
для render-функции уведомлений, проверяемой тем же таргетом.

## Запрещено

- Рендерить в иконку содержимое писем / тему.
- Держать в памяти список всех писем — только агрегированные счётчики.
- Использовать AppKit (NSStatusItem) — только SwiftUI MenuBarExtra.
