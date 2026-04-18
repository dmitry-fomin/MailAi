# Агент: SwiftUI + AppKit

## Область

UI-слой macOS-приложения: SwiftUI как основа, AppKit — там, где SwiftUI не справляется.

## Когда SwiftUI, когда AppKit

- **SwiftUI по умолчанию**: views, навигация, toolbar, settings, menu bar content.
- **AppKit через `NSViewRepresentable`**:
  - Виртуализация больших списков (100k+ писем) — `NSTableView` с view-based cells.
  - Сложная клавиатурная навигация и first-responder chain.
  - `NSStatusItem` в `StatusBar` модуле.
  - `NSSavePanel`/`NSOpenPanel` для сохранения вложений.
  - `QLPreviewView` для превью вложений.

## Архитектура view-слоя

- **MVVM**: View → ViewModel → Services.
- ViewModel — `@Observable` class, `@MainActor`. Не знает про транспорт/БД напрямую — только через протоколы из `Core`.
- Views без бизнес-логики. Форматирование дат/размеров — через helpers в `UI` модуле.
- **Не** помещайте `@State` на то, что должно жить в ViewModel.

## Многооконность

- `WindowGroup` для окон-аккаунтов, каждое окно получает свой `AccountSession` через `.environment(...)`.
- State restoration для набора открытых окон (без содержимого).
- `@Environment(\.openWindow)` для открытия новых окон из menu / StatusBar.

## Производительность

- Список писем — `List` работает до ~10k; выше — AppKit-таблица.
- `LazyVStack`/`LazyHStack` для длинных прокручиваемых layout-ов.
- Избегаем `AnyView` — стираем тип, но теряем оптимизации diff.
- Изображения аватаров/иконок — `AsyncImage` с кешем в памяти, лимитированным по размеру.

## Темы и доступность

- Полная поддержка Light/Dark (система).
- Dynamic Type, VoiceOver — проверяем ключевые экраны.
- Семантические цвета (`.primary`, `.secondary`), не хардкодим HEX.

## Запрещено

- Сторонние UI-библиотеки (Introspect, SnapKit, SwiftUI-компоненты от третьих лиц).
- Бизнес-логика во view/body.
- `print` для отладки UI — логгер.
- Обращения к Storage/Transport/AI напрямую из view — только через ViewModel.
