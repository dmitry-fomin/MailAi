# Агент: Mail Protocols

## Область

Транспорт писем: IMAP4rev1, SMTP (для отправки из IMAP-аккаунтов), Exchange (EWS или Microsoft Graph).

## IMAP

- Пагинация по **UID**, не по sequence numbers (sequence меняется при удалениях).
- `UIDVALIDITY` проверяется на каждом подключении к mailbox — если изменился, локальный индекс инвалидируется.
- `FETCH` списка: только заголовки (`ENVELOPE BODYSTRUCTURE FLAGS UID INTERNALDATE RFC822.SIZE`), без `BODY[]`.
- `BODY[]` — только по явному запросу пользователя, стримим по частям через `BODY[]<offset.size>` при больших телах.
- Удаление: `UID STORE <ids> +FLAGS (\Deleted)` + `UID EXPUNGE` (RFC 4315). Для Gmail — move в `[Gmail]/Trash`.
- **IDLE** (RFC 2177) для push-уведомлений о новых письмах; fallback — poll с большим интервалом.
- Соединение: TLS обязателен, `STARTTLS` только если сервер не поддерживает `imaps`.
- Keep-alive: re-IDLE каждые ~29 минут (до таймаута роутеров).

## SMTP

- Отправка через `SUBMISSION` (port 587) + STARTTLS. Без 25 порта и без plain 465 кроме случая явной конфигурации.
- Аутентификация: PLAIN/LOGIN/CRAM-MD5/XOAUTH2.
- Для Gmail/Outlook — обязательно OAuth2, app passwords только как fallback.
- Ошибки 4xx — retry с backoff; 5xx — окончательные, не ретраим.

## Exchange

- **Предпочтение — Microsoft Graph** (OAuth2, REST, современнее). EWS — fallback для on-prem серверов.
- Graph: `/me/mailFolders/{id}/messages` для списков, `$select` для ограничения полей, `$top`/`@odata.nextLink` для пагинации.
- Batch-запросы через `$batch` для массовых операций (удаление, маркировка).
- Subscription для push (`/subscriptions`) — webhook'ов у нас нет, используем `deltaLink` polling.
- Throttling: уважаем `Retry-After` и `x-ms-retry-count`.

## Общие правила

- **Тела писем не кешируются на диске** — противоречит политике приватности.
- Парсинг MIME — стриминговый, не держим всё письмо в памяти.
- Charset: корректная декодировка по `Content-Type; charset=...`, fallback на UTF-8.
- Header unfolding и RFC 2047 encoded-words — обязательно.
- Сетевые таймауты: 30 сек на операцию, 10 сек на подключение.
- Логгируем счётчики и коды ошибок, **не** содержимое.

## Запрещено

- Хранить логины/пароли вне Keychain.
- Использовать sequence numbers вместо UID в IMAP.
- Повторно скачивать тело письма, уже загруженное в память в текущей сессии.
- Парсить MIME руками без тестов на corpus-е реальных писем.
