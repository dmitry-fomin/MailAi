# Keychain Services (Apple Security.framework)

**Роль в проекте**: хранение паролей IMAP, OAuth-токенов, API-ключей OpenRouter (модуль `Secrets`).

Мы используем **Security.framework напрямую**, без сторонних обёрток (`KeychainSwift` и т.п.) — по политике «минимум зависимостей» и чтобы контролировать поведение.

## Добавить пароль (generic password)

```swift
import Security

func setPassword(_ value: String, service: String, account: String) throws {
    let data = value.data(using: .utf8)!
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,   // "mailai.imap"
        kSecAttrAccount as String: account,   // "<accountId>"
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecValueData as String: data,
    ]
    // upsert: сначала удалить, потом добавить
    SecItemDelete(query as CFDictionary)
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw KeychainError.osStatus(status)
    }
}
```

## Прочитать

```swift
func getPassword(service: String, account: String) throws -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        guard let data = result as? Data, let str = String(data: data, encoding: .utf8) else {
            throw KeychainError.decoding
        }
        return str
    case errSecItemNotFound:
        throw KeychainError.notFound
    default:
        throw KeychainError.osStatus(status)
    }
}
```

## Удалить

```swift
func deletePassword(service: String, account: String) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError.osStatus(status)
    }
}
```

## Ключевые атрибуты

- `kSecClassGenericPassword` — для наших нужд. `kSecClassInternetPassword` — только если нужны URL-specific атрибуты (не нужны).
- `kSecAttrService` — логический «домен» секрета. Схема: `mailai.<kind>` (`mailai.imap`, `mailai.openrouter`).
- `kSecAttrAccount` — идентификатор пользователя секрета. У нас — `<accountId>` (uuid).
- `kSecAttrAccessible`:
  - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — **наш дефолт**. Не синкается в iCloud, доступен только когда разблокирован.
  - `AfterFirstUnlockThisDeviceOnly` — если нужен фоновый доступ до первой разблокировки (не наш случай).
  - **Никогда не `Always`** — deprecated и небезопасно.
- `kSecAttrSynchronizable` — `false` (по умолчанию). Синкать пароли в iCloud мы не хотим.

## Access Control (опционально)

Для особо чувствительных секретов (API-ключ OpenRouter) можно требовать биометрию:

```swift
var error: Unmanaged<CFError>?
let accessControl = SecAccessControlCreateWithFlags(
    nil,
    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    [.biometryCurrentSet],
    &error
)!
// использовать в query как kSecAttrAccessControl
```

В MVP — **не включаем**, чтобы не создавать UX-трение.

## OSStatus → Error

```swift
enum KeychainError: Error {
    case notFound
    case decoding
    case osStatus(OSStatus)
}
```

- `errSecSuccess` = 0.
- `errSecItemNotFound` = −25300.
- `errSecDuplicateItem` = −25299 (если не удаляли перед add).
- `errSecAuthFailed` = −25293 (неверный доступ).
- `errSecUserCanceled` = −128 (пользователь отменил биометрию).

Для расшифровки: `SecCopyErrorMessageString(status, nil)` — возвращает localized-строку, но её **не логируем** (может содержать путь / account hint).

## Частые ошибки

- **Забыть удалить перед `SecItemAdd`** → `errSecDuplicateItem`. Использовать upsert-паттерн или `SecItemUpdate`.
- **Разный `kSecAttrAccessible` у `Add` и `CopyMatching`** → не находит. В `CopyMatching` этот атрибут не указываем, только класс/service/account.
- **Sandbox**: App Sandbox включён → Keychain access group автоматически ограничен bundle'ом приложения. Не пытаться использовать shared group без явной конфигурации entitlement.
- **Строку хранить как `Data`**: не забываем encoding UTF-8 туда и обратно.
- **Логировать значения**: никогда. В отладочных логах — только `{service, account, status}`, и то при ошибке.
- **Sync Keychain для паролей почты** — плохая идея. `ThisDeviceOnly` атрибуты.

## Keychain Access.app для отладки

- `Keychain Access` показывает наши items в login keychain с префиксом service.
- В Xcode при запуске из sandbox-а — items уходят в отдельный файл, **не** в login.keychain.

## Entitlements

- `com.apple.security.app-sandbox` = `true`.
- `keychain-access-groups` — **не** добавляем (не нужен shared access).

## Ссылки

- https://developer.apple.com/documentation/security/keychain_services
- Access control flags: https://developer.apple.com/documentation/security/secaccesscontrolcreateflags
