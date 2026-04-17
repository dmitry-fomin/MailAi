# Модуль: Notifications

<!-- Статус: план модуля. Код ещё не написан. -->

## Назначение

Уведомления о новых письмах: системные (`UserNotifications`) плюс внутриприложенческие (toast/bezel). Интеграция с AI-оценкой важности — неважные рассылки не шумят.

## Ключевые сущности

- `NotificationCenter` (доменный, не путать с `Foundation.NotificationCenter`) — актёр.
- `NotificationPolicy` — правила показа (только важные / все / никакие / по времени).
- `NotificationPresenter` — обёртка над `UNUserNotificationCenter`.

## Бизнес-логика

- По умолчанию: уведомления показываются **только** для писем с `Importance == .high` по AI-оценке.
- Правила настраиваются на аккаунт (разные политики для разных ящиков).
- Текст уведомления — тема + имя отправителя. **Тело письма в уведомление не попадает** (совместимо с требованием приватности).
- Нажатие на уведомление — открывает окно соответствующего аккаунта и фокусирует письмо.

## API

```swift
public protocol NotificationService: Sendable {
    func requestAuthorization() async -> Bool
    func notify(newMessages: [Message], in: Account.ID) async
    func updatePolicy(_ policy: NotificationPolicy, for: Account.ID) async
}
```

## Зависимости

- **От**: `Core`, `UserNotifications`.
- **Кто зависит**: `AppShell`, `StatusBar`.

## Запрещено

- Включать содержимое письма в текст уведомления.
