# Email Renderer — Спецификация

**Дата:** 2026-04-28  
**Статус:** Согласовано, готово к реализации  
**Область:** `Packages/UI` — `ReaderBodyView` и связанные компоненты

---

## Контекст

Текущий `ReaderBodyView` рендерит HTML-письма как plain text через `HTMLSanitizer.plainText()` — это временная заглушка (отмечено в коде). Цель — полноценный рендер на уровне Apple Mail / Outlook.

**Изменение политики хранения:** тела писем и вложения кешируются на диск в `~/Library/Caches/MailAi/`. Это осознанное отступление от исходного правила «никакого контента на диске». `CLAUDE.md` обновить отдельным коммитом.

---

## Архитектура

Пять новых / изменённых компонентов в `Packages/UI`:

```
ReaderBodyView (изменить)
    ├── HTMLPreprocessor        (новый, actor)
    ├── MessageWebView          (новый, NSViewRepresentable)
    │       └── MessageWebViewController  (новый, NSViewController)
    └── MailCIDSchemeHandler    (новый, WKURLSchemeHandler)

Packages/UI/Cache/
    ├── MessageBodyCache        (новый, actor)
    ├── AttachmentCacheStore    (новый, actor)
    └── CacheManager            (новый, actor)
```

### Поток данных

```
open(messageID)
  └─ MessageBodyCache.read(messageID)
       ├─ hit  → processedHTML → WKWebView.loadHTMLString()
       └─ miss → IMAP fetch → HTMLPreprocessor.process()
                    └─ MessageBodyCache.write(processedHTML)
                         └─ WKWebView.loadHTMLString()

cid:<contentID> (запрос из WKWebView)
  └─ AttachmentCacheStore.read(messageID, contentID)
       ├─ hit  → data → WKURLSchemeTask.didReceive(data)
       └─ miss → IMAP fetch part → AttachmentCacheStore.write()
                    └─ WKURLSchemeTask.didReceive(data)

смена системной темы
  └─ WKUserScript (уже в конфиге WKWebView) применяется автоматически
     кеш не инвалидируется
```

---

## Компоненты

### HTMLPreprocessor

Swift `actor`. Принимает сырой HTML-строку от IMAP, возвращает готовый HTML для WKWebView.

**Трансформации (в порядке применения):**

1. **CSP meta-тег** — вставляет `<meta http-equiv="Content-Security-Policy" content="script-src 'none'">` в `<head>`. Дополнительный барьер поверх `allowsContentJavaScript = false`.

2. **Viewport meta** — `<meta name="viewport" content="width=device-width, initial-scale=1">`.

3. **Base styles** — инжектирует `<style>` с:
   ```css
   * { max-width: 100%; box-sizing: border-box; }
   body { word-wrap: break-word; overflow-wrap: break-word; }
   img { height: auto; }
   ```

4. **Quote collapsing** — детектирует блоки цитат по паттернам и оборачивает в `<details class="mail-quote"><summary>Предыдущие сообщения</summary>…</details>`:
   - `div.gmail_quote`, `div[class*="gmail_quote"]` — Gmail
   - `blockquote[type="cite"]`, `div.AppleOriginalContents` — Apple Mail
   - `div[id^="divRplyFwdMsg"]`, `div[id^="x_divRplyFwdMsg"]` — Outlook/Exchange
   - `hr[id="stopSpelling"]` и всё после него — Outlook separator
   - `blockquote` верхнего уровня (не вложенный в другой `blockquote`) — fallback

   Стили `<details.mail-quote>` инжектируются как часть base styles.

5. **Dark mode check** — проверяет наличие `prefers-color-scheme` в HTML/CSS. Результат (`Bool`) сохраняется и передаётся в `MessageWebViewController` для принятия решения об инъекции CSS.

**Сигнатура:**
```swift
actor HTMLPreprocessor {
    func process(_ rawHTML: String) async -> ProcessedEmail
}

struct ProcessedEmail {
    let html: String
    let hasDarkModeSupport: Bool
}
```

---

### MessageWebView

`NSViewRepresentable`, оборачивающий `WKWebView`. Создаёт конфигурацию один раз при инициализации.

**Конфигурация WKWebView:**
```swift
let config = WKWebViewConfiguration()
config.defaultWebpagePreferences.allowsContentJavaScript = false
config.setURLSchemeHandler(MailCIDSchemeHandler(cache:), forURLScheme: "cid")
config.preferences.setValue(false, forKey: "allowFileAccessFromFileURLs")
config.userContentController.addUserScript(darkModeUserScript)   // at documentEnd
config.userContentController.addUserScript(baseStylesUserScript) // at documentStart
```

`darkModeUserScript` инжектируется при каждом открытии письма через `evaluateJavaScript` с учётом флага `hasDarkModeSupport` из `ProcessedEmail`.

**Загрузка письма:**
```swift
// При смене письма — сначала очистить
webView.loadHTMLString("", baseURL: nil)
// Затем загрузить новое
webView.loadHTMLString(processedEmail.html, baseURL: URL(string: "about:blank"))
```

---

### MessageWebViewController

`NSViewController`, выступает `WKNavigationDelegate` и `WKUIDelegate`.

**Навигационная политика (`decidePolicyFor navigationAction`):**

| URL / тип | Действие |
|-----------|----------|
| `about:blank` (начальная загрузка) | `.allow` |
| `cid:` subresource | обрабатывает `MailCIDSchemeHandler` |
| `https://` subresource (img, css) | грузит WebKit нативно |
| `data:image/*` subresource | грузит WebKit нативно |
| `https://` ссылка (клик) | `.cancel` + `NSWorkspace.shared.open(url)` |
| `http://` | `.cancel` |
| `data:` навигация | `.cancel` |
| `file:`, `javascript:`, прочее | `.cancel` |

**Тёмная тема:** подписывается на `NSApp.effectiveAppearance` через KVO. При смене темы вызывает `evaluateJavaScript` для обновления CSS-инъекции — без перезагрузки письма.

---

### MailCIDSchemeHandler

Реализует `WKURLSchemeHandler`. Перехватывает запросы `cid:<contentID>`.

```swift
// WKURLSchemeHandler — @objc протокол, актор не подходит.
// Используем NSObject + внутренний актор для кеша.
final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler {
    private let cache: AttachmentCacheStore
    private(set) var currentMessageID: String = ""

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let contentID = urlSchemeTask.request.url?.host ?? ""
        let msgID = currentMessageID
        Task {
            if let (data, mimeType) = await cache.read(messageID: msgID, contentID: contentID) {
                // respond with data
            } else {
                // IMAP fetch → cache.write() → respond
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
```

`currentMessageID` выставляется из `MessageWebViewController` перед вызовом `loadHTMLString()`.

Данные вложений проходят через `AttachmentCacheStore`, на диск пишутся бинарно. В памяти удерживается только то, что сейчас отдаётся в WKWebView.

---

### Слой кеша

**Структура на диске:**
```
~/Library/Caches/MailAi/
  bodies/
    {sha256(messageID)}.html          ← обработанный HTML (после preprocessor)
  attachments/
    {sha256(messageID+contentID)}.bin ← бинарные данные вложения
    {sha256(messageID+contentID)}.meta ← mimeType, size (JSON)
```

Имена файлов — SHA-256, контент не читается по имени. `~/Library/Caches` macOS вправе очистить при нехватке места.

**MessageBodyCache** (`actor`):
- `read(messageID: String) async -> String?`
- `write(messageID: String, processedHTML: String) async`
- `invalidate(messageID: String) async`
- `clearAll() async -> Int` — возвращает освобождённые байты

**AttachmentCacheStore** (`actor`):
- `read(messageID: String, contentID: String) async -> (Data, String)?` — (data, mimeType)
- `write(messageID: String, contentID: String, data: Data, mimeType: String) async`
- `clearAll() async -> Int`

**CacheManager** (`actor`) — фасад для Settings UI:
- `totalSize() async -> Int` — сумма обоих кешей
- `clearAll() async` — очищает `bodies/` + `attachments/`

---

## Dark Mode CSS

Инжектируется как `WKUserScript` при `documentEnd`, обновляется через `evaluateJavaScript` при смене системной темы.

**Логика:**
```
if !isDarkMode → не инжектируем ничего
if isDarkMode && hasDarkModeSupport → не инжектируем (уважаем стили письма)
if isDarkMode && !hasDarkModeSupport → инжектируем:
  html { filter: invert(1) hue-rotate(180deg); }
  img, video, picture { filter: invert(1) hue-rotate(180deg); }
```

---

## Settings UI

Фрагмент в `SettingsView` (существующий экран настроек):

```swift
Section("Кеш") {
    HStack {
        VStack(alignment: .leading) {
            Text("Письма и вложения")
            Text(cacheManager.formattedSize)  // "124 МБ"
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        Spacer()
        Button("Очистить кеш", role: .destructive) {
            Task { await cacheManager.clearAll() }
        }
    }
}
```

---

## Изменения в существующих файлах

| Файл | Изменение |
|------|-----------|
| `ReaderBodyView.swift` | Заменить `HTMLSanitizer` + `Text` на `MessageWebView` для `.html`; plain text оставить как есть |
| `CLAUDE.md` | Обновить политику хранения: добавить раздел про `~/Library/Caches/MailAi/` |
| `docs/UI.md` | Добавить описание новых компонентов |
| `docs/Storage.md` | Добавить раздел про кеш (отдельно от GRDB) |

---

## Out of scope (v1)

- Zoom controls
- Print
- Блокировка внешних изображений / трекер-пиксели
- Лимит размера кеша (TTL, LRU eviction) — только ручная очистка
- Офлайн-режим для вложений (скачать заранее)
