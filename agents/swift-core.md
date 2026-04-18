# Агент: Swift Core

## Область

Язык Swift и его идиомы: типы, generics, протоколы, error handling, конкурентность, владение.

## Concurrency (жёстко)

- **Strict Concurrency Checking** включён на уровне пакетов (`swiftSettings: .enableUpcomingFeature("StrictConcurrency")`).
- `async/await` + структурированная конкурентность. **Запрещены** completion handlers, `DispatchQueue.main.async`, `Thread.sleep`.
- Изолированное состояние — через `actor`. Общие иммутабельные данные — `Sendable`.
- UI — `@MainActor`. Сервисы — отдельные акторы.
- `Task` — всегда с явной отменой. Долгие операции проверяют `Task.isCancelled`.
- `AsyncStream` / `AsyncSequence` для реактивных потоков. **Combine не используем** в новом коде.

## Типы и API

- `struct` по умолчанию, `class` — только когда нужна identity или `deinit`.
- `enum` с associated values для state machines и ошибок.
- `Result` — не используем, есть `try/await`.
- Protocol-oriented: сервисы за протоколами для тестируемости, но без абстракций «про запас».
- `@Observable` (iOS 17 / macOS 14+) вместо `ObservableObject`, если минимальная версия позволяет.

## Ошибки

- Типизированные `enum Error: Error` на модуль.
- `throws` с конкретным типом (Swift 6) — где возможно.
- Никаких `try!`. `try?` — только с осознанной потерей ошибки и комментарием почему.
- `fatalError` — только для programmer errors (недостижимые ветки).

## Память

- `weak`/`unowned` в замыканиях там, где есть риск цикла (обычно — внутри `Task` с захватом `self` в view model).
- Большие данные (тела писем) — `Data` не копируем без нужды, используем срезы / стримы.
- `autoreleasepool` вокруг циклов, которые создают много NSObject.

## Code Style

- SwiftLint + swift-format. Правила в `.swiftlint.yml`, warnings = errors в CI.
- Имена: Swift API Design Guidelines.
- Файл = один основной тип. Вложенные типы — в том же файле.

## Запрещено

- `DispatchQueue`, `OperationQueue`, `Thread` в новом коде.
- Completion handlers (кроме обёрток системных API через `withCheckedContinuation`).
- Force unwrap (`!`) и `try!`.
- Синглтоны для сервисов. Только явная инъекция зависимостей.
- `NSNotification` для бизнес-событий (только `AsyncStream` / observer-протоколы).
