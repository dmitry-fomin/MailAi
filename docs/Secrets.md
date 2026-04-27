# Модуль: Secrets

<!-- Статус: KeychainService + SecretsStore (Kind.imapPassword, Kind.openrouter, Kind.smtpPassword) реализованы; InMemorySecretsStore для тестов. -->

## Назначение

Единственный легитимный канал доступа к секретам: паролям IMAP/Exchange, OAuth-токенам, API-ключу OpenRouter. Обёртка над macOS Keychain с чётким scope.

## Ключевые сущности

- `KeychainService` — актёр с операциями get/set/delete.
- `SecretReference` — opaque-идентификатор секрета, который безопасно хранить в БД/моделях.

## Бизнес-логика

- Keychain access group — только для этого app-bundle, без sharing.
- Ключи именуются по схеме: `mailai.<accountId>.<kind>`, где kind = `imapPassword`, `exchangeRefreshToken`, `openrouterApiKey`, `smtpPassword` и т.п.

### `Kind.smtpPassword` (SMTP-3)

Отдельный ключ для SMTP-пароля. Причина — у Gmail/Yandex/iCloud SMTP-доступ
часто требует application-password, не совпадающий с IMAP-паролем.

Контракт API:

- `SecretsStore.setSMTPPassword(_:forAccount:)` / `smtpPassword(forAccount:)` /
  `deleteSMTPPassword(forAccount:)` — ровно symmetric с IMAP-паролем.
- **Fallback-семантика**: реализуется не в `SecretsStore`, а в потребителе
  (`LiveSendProvider`): если `smtpPassword` не задан / пуст, провайдер
  читает обычный `password` (IMAP) того же аккаунта. Сам store fallback
  не делает — это явное архитектурное решение, чтобы тесты могли
  отдельно проверять поведение «есть только IMAP» vs «оба заданы».
- Удаление аккаунта → каскадное удаление всех его секретов.
- `SecurityInteraction` (биометрия/пароль) — опционально; по умолчанию выключено в MVP.

## API

```swift
public protocol SecretsProtocol: Sendable {
    func read(_ ref: SecretReference) async throws -> String
    func write(_ value: String, as ref: SecretReference) async throws
    func delete(_ ref: SecretReference) async throws
}
```

## Зависимости

- **От**: `Core`, Security.framework.
- **Кто зависит**: `MailTransport`, `AI`, `AppShell`.

## Запрещено

- Логировать значения секретов (даже длину, кроме случая «отсутствует / присутствует»).
- Хранить секреты в UserDefaults, plist, БД, файлах.
- Передавать секреты через `Notification` или `pasteboard`.
