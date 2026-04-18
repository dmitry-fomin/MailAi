# Модуль: Secrets

<!-- Статус: план модуля. Код ещё не написан. -->

## Назначение

Единственный легитимный канал доступа к секретам: паролям IMAP/Exchange, OAuth-токенам, API-ключу OpenRouter. Обёртка над macOS Keychain с чётким scope.

## Ключевые сущности

- `KeychainService` — актёр с операциями get/set/delete.
- `SecretReference` — opaque-идентификатор секрета, который безопасно хранить в БД/моделях.

## Бизнес-логика

- Keychain access group — только для этого app-bundle, без sharing.
- Ключи именуются по схеме: `mailai.<accountId>.<kind>`, где kind = `imapPassword`, `exchangeRefreshToken`, `openrouterApiKey` и т.п.
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
