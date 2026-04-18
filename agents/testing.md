# Агент: Testing

## Область

Стратегия и практики тестирования: что тестируем, чем, как мокируем.

## Инструменты

- **Swift Testing** (`import Testing`, `@Test`) — основной, если минимальная версия macOS позволяет (macOS 14+).
- **XCTest** — fallback для того, что Swift Testing пока не покрывает (performance-тесты, UI-тесты).
- Асинхронные тесты — `async` функции, `confirmation` для событий, `withCheckedContinuation` для мостов.

## Что тестируем обязательно

- Парсинг MIME, headers, encoded-words (corpus реальных писем в `Tests/Fixtures/`).
- IMAP/Exchange transport — через протоколы с fake-серверами или recorded responses.
- GRDB-миграции — fixture старой версии БД → применяем миграции → проверяем схему.
- Бизнес-логика массового удаления — AI-advisor возвращает кандидатов, реальное удаление только после подтверждения.
- Конкурентность — race conditions в `MetadataStore` actor, отмена `Task`, освобождение ресурсов.

## Что тестируем опционально

- Views — smoke-тесты (view рендерится без крэша); snapshot-тесты — **не** добавляем, сторонняя библиотека.
- ViewModels — state transitions, реакция на события сервисов.

## Моки

- Моки через протоколы из `Core`. Реализация `Fake*` / `Mock*` — в `Tests/Support/`.
- **Не** используем OCMock / Swift-моки через reflection.
- Тестовые данные — `MessageFactory`, `AccountFactory` с дефолтами и билдерами.

## Правила

- Тест называется по поведению: `test_bulkDelete_withoutConfirmation_doesNotDelete`.
- One assertion per test — рекомендация, не догма.
- Тесты не должны обращаться к сети. Если обращаются — `@Suite(.disabled)` или отдельный CI-job.
- Тесты не должны писать в реальный Keychain. Используем in-memory fake.
- Flaky-тесты фиксим или удаляем — не терпим.

## Покрытие

- Целевое: 70%+ для модулей `Core`, `MailTransport`, `Storage`, `AI`.
- UI-модули не учитываются в покрытии (ловим руками / через UI-тесты).

## CI

- Sanitizers: Thread Sanitizer для тестов конкурентности.
- Strict Concurrency на уровне warnings — падаем на любом.

## Запрещено

- Тесты, зависящие от системного времени без `Clock` abstraction.
- Тесты, делающие реальные HTTP-запросы к OpenRouter / почтовым серверам.
- Использование `sleep()` для синхронизации — `Task.yield` / confirmation-паттерн.
- Коммит «skip для обхода CI».
