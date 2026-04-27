# Модуль: Notifications

## Назначение

Системные уведомления о новых письмах (`UNUserNotificationCenter`) с
приватностью по умолчанию. Интеграция с AI-оценкой важности — неважные
рассылки не раскрывают данные отправителя/темы.

## Ключевые сущности

- `NotificationManager` — singleton-менеджер уведомлений (`UI`-модуль).
- `NotificationDelegate` — делегат для отображения баннеров в foreground.

## Модель приватности

| Состояние письма | Заголовок | Тело уведомления | Что видно |
|---|---|---|---|
| AI не классифицировал (`isImportant = false`) | MailAi | «Новое письмо в \<аккаунт\>» | Только наличие нового письма |
| AI одобрил как важное (`isImportant = true`) | Sender (имя/адрес) | Subject (тема) | Отправитель + тема |
| **Любое** | — | — | **Тело/сниппет НИКОГДА не показываются** |

### Почему так

По умолчанию приложение не знает, является ли письмо важным (спам,
рассылка, маркетинг). Пока AI-pack не классифицировал письмо, мы не
раскрываем отправителя и тему — пользователь видит только generic
уведомление. После AI-одобрения показываем полную информацию.

## Когда запрашивается разрешение

Один раз — при добавлении **первого** аккаунта:

- `WelcomeOrPickerScene`: кнопка «Продолжить с демо-данными».
- `OnboardingWindow`: завершение онбординга живого аккаунта.

Повторные вызовы `requestPermission()` безопасны — система запоминает
выбор пользователя.

## Foreground-уведомления

macOS по умолчанию не показывает баннеры, если приложение активно.
`NotificationDelegate` реализует `willPresent` и возвращает `[.banner, .sound]`,
чтобы уведомления отображались всегда.

Делегат устанавливается через `AppDelegate` → `NotificationManager.setupDelegate()`
в `applicationDidFinishLaunching`.

## API

```swift
// UI-модуль, Packages/UI/Sources/UI/NotificationManager.swift

public final class NotificationManager: @unchecked Sendable {
    public static let shared = NotificationManager()

    /// Установить делегат (вызывается при запуске приложения).
    public func setupDelegate()

    /// Запросить разрешение на уведомления (один раз).
    public func requestPermission() async -> Bool

    /// Показать уведомление о новом письме.
    public func notify(
        accountName: String,
        accountID: String,
        subject: String? = nil,
        sender: String? = nil,
        isImportant: Bool = false
    )

    /// Удалить доставленные уведомления для аккаунта.
    public func removeDeliveredNotifications(for accountID: String)
}
```

### Параметры `notify`

- `accountName` — отображаемое имя аккаунта (email или displayName).
- `accountID` — уникальный идентификатор аккаунта. Используется для
  группировки уведомлений (`threadIdentifier`) и их удаления.
- `subject` — тема письма (видна только при `isImportant == true`).
- `sender` — имя/адрес отправителя (видно только при `isImportant == true`).
- `isImportant` — признак AI-одобрения. `false` = generic уведомление.

### Параметры `removeDeliveredNotifications`

- `accountID` — идентификатор аккаунта, ранее переданный в `notify(accountID:…)`.

## Пример использования

```swift
// Новое письмо, AI ещё не классифицировал:
NotificationManager.shared.notify(
    accountName: "user@gmail.com",
    accountID: "acc-123"
)
// → Заголовок: "MailAi"
// → Тело: "Новое письмо в user@gmail.com"

// AI одобрил как важное:
NotificationManager.shared.notify(
    accountName: "user@gmail.com",
    accountID: "acc-123",
    subject: "Срочно: отчёт за Q4",
    sender: "Директор Иванова",
    isImportant: true
)
// → Заголовок: "Директор Иванова"
// → Тело: "Срочно: отчёт за Q4"

// Очистить уведомления при переключении аккаунта:
NotificationManager.shared.removeDeliveredNotifications(for: "acc-123")
```

## Зависимости

- **От**: `Core`, `UserNotifications`.
- **Кто зависит**: `AppShell` (интеграция), `MailAiApp` (запуск).

## Status-3 — smoke без UNUserNotificationCenter

`StatusNotificationsSmoke` (executable-таргет в `Packages/UI`) проверяет
payload-логику без обращения к UN-фреймворку. Чтобы это было возможно,
формирование `(title, body)` вынесено в чистую render-функцию:

```swift
static func renderNotification(
    accountName: String,
    subject: String?,
    sender: String?,
    classification: FakeClassification  // .important / .notImportant / .suppressed
) -> (title: String, body: String)?
```

Контракт:

- `.important` → `(title: sender ?? "Новое важное письмо", body: subject ?? …)`.
- `.notImportant` → `(title: "MailAi", body: "Новое письмо в \(accountName)")`.
- `.suppressed` → `nil` (уведомление полностью гасится AI-фильтром).

Smoke прогоняет утечки: subject/sender не должны попадать в generic-payload.
Сигнатура render намеренно **не принимает** body/snippet — это статическая
гарантия privacy-инварианта.

## Запрещено

- Включать содержимое письма (body/snippet/preview) в текст уведомления.
- Показывать subject/sender для неклассифицированных или неважных писем.
