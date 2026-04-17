# Агент: Security & Privacy

## Область

Секреты, Keychain, sandbox, entitlements, пресечение утечек данных.

## Keychain

- Все секреты (пароли IMAP, OAuth-токены, API-ключ OpenRouter) — только в Keychain.
- Access group — уникальный для приложения, **не** shared.
- Ключи: `mailai.<accountId>.<kind>`. Удаление аккаунта каскадно удаляет его ключи.
- При чтении/записи — обрабатываем `errSecItemNotFound`, `errSecAuthFailed` явно.

## Sandbox и entitlements

- App Sandbox — включён.
- Сеть — `com.apple.security.network.client` (мы клиент, не сервер).
- Файлы — `com.apple.security.files.user-selected.read-write` (для Save As вложений).
- **Нет** `files.downloads.read-write` или broad file access — только user-selected.
- Hardened Runtime — включён.
- Нет entitlements «на вырост». Только то, что реально используется.

## Что никогда не попадает в логи

- Тела писем, их фрагменты, snippet'ы.
- Email-адреса (ни from, ни to).
- Пароли, токены, API-ключи.
- Content-ID / Message-ID в открытом виде (только хеши, если нужно для корреляции).

Логи содержат: счётчики, тайминги, коды ошибок, идентификаторы операций.

## Что не пишется на диск

- Тела писем, HTML-представления, plain text представления.
- Вложения — автоматически никогда, только по `NSSavePanel` от пользователя.
- Временные превью (`QLPreviewView`) — удаляются при закрытии письма / выгрузке view.
- Крашдампы не должны содержать писем — **проверять**: в `@State` не хранить `MessageBody`, только `body: MessageBody?` в ViewModel с явным nil-ованием при уходе с экрана.

## Сеть

- TLS обязателен. `NSAppTransportSecurity` — без exceptions.
- Certificate pinning — **не** для всех серверов (ломается при смене серта); рассматриваем только для API OpenRouter.
- Прокси — уважаем системные настройки, но логируем факт (без содержимого).

## Обработка пользовательского ввода

- Поля из писем (subject, from) — не интерпретируем как разметку/HTML без санитайзинга.
- Ссылки в письмах — открываем только по явному клику, показываем полный URL в tooltip.
- Внешние изображения в HTML — **не** загружаются автоматически (tracking-пиксели); пользователь явно разрешает на письмо.

## Аудит

- Чек-лист перед релизом: grep по `print(`, проверка логгера на whitelisted контент, проверка crash-репортов на содержимое писем.

## Запрещено

- Shared Keychain access group.
- `com.apple.security.temporary-exception.*` entitlements.
- Загрузка удалённого содержимого в HTML-письмах без подтверждения.
- Сохранение любых персональных данных в UserDefaults/plist.
- Телеметрия, отправляющая что-либо за пределы приложения по умолчанию.
