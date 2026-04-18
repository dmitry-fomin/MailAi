# OpenRouter API

**Library ID (Context7)**: `/llmstxt/openrouter_ai_llms_txt`
**Роль в проекте**: единственный AI-провайдер (модуль `AI`).

Клиент пишем **сами**, `URLSession + async/await`, без SDK.

## Endpoint

```
POST https://openrouter.ai/api/v1/chat/completions
```

## Заголовки

| Header | Значение | Обязательность |
|---|---|---|
| `Authorization` | `Bearer <API_KEY>` | **Да** |
| `Content-Type` | `application/json` | **Да** |
| `HTTP-Referer` | `https://mailai.app` (или placeholder) | Рекомендуется (аналитика на OpenRouter) |
| `X-Title` | `MailAi` | Рекомендуется |

## Тело запроса

```json
{
  "model": "anthropic/claude-haiku-4.5",
  "messages": [
    {"role": "system", "content": "Ты ассистент почты. Кратко, на языке письма. Не выдумывай."},
    {"role": "user", "content": "Суммаризуй: ..."}
  ],
  "temperature": 0.2,
  "max_tokens": 512,
  "stream": true
}
```

## Клиент (базовый каркас)

```swift
struct OpenRouterClient: Sendable {
    let apiKey: String           // из Keychain
    let model: String            // из настроек
    let session: URLSession      // .shared или кастомный с таймаутами

    func complete(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("https://mailai.app", forHTTPHeaderField: "HTTP-Referer")
                    req.setValue("MailAi", forHTTPHeaderField: "X-Title")
                    req.httpBody = try JSONEncoder().encode(
                        ChatRequest(model: model, messages: messages, stream: true)
                    )
                    let (bytes, response) = try await session.bytes(for: req)
                    try validate(response)
                    for try await line in bytes.lines {
                        // SSE: строки вида "data: {...}" и "data: [DONE]"
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        if let delta = try? decodeDelta(payload) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

## Streaming (SSE)

- `stream: true` в теле → ответ — Server-Sent Events.
- Каждое событие: `data: { ... chunk ... }\n\n`.
- Финал: `data: [DONE]`.
- Чанк содержит `choices[0].delta.content` — инкрементальный текст.
- Используем `URLSession.bytes(for:)` → `bytes.lines` для построчного разбора, не тянем в память целиком.

## Non-streaming ответ

```json
{
  "id": "gen-...",
  "model": "...",
  "choices": [
    {
      "index": 0,
      "message": {"role": "assistant", "content": "..."},
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 20,
    "completion_tokens": 8,
    "total_tokens": 28
  }
}
```

## Ошибки

- **401** — неверный API-ключ. Показать пользователю «проверьте ключ в настройках».
- **402** — нет средств на счёте.
- **429** — rate limit. Уважаем `Retry-After` если есть, иначе — backoff.
- **5xx** — retry с экспоненциальным backoff (1s, 2s, 4s, 8s, max 60s).
- **400** — битый запрос, не ретраим.

## Выбор модели

- ID формата `<provider>/<model>`: `openai/gpt-4o`, `anthropic/claude-haiku-4.5`, `google/gemini-2.5-flash`, `deepseek/deepseek-chat`.
- Список актуальных моделей: `GET /api/v1/models`.
- **Не хардкодим** — в настройках пользователя + дефолт в конфиге.

## Частые ошибки

- **Забыть `HTTP-Referer`/`X-Title`** — работать будет, но в аналитике OpenRouter нас не видно.
- **Логировать тело запроса или ответа** — нарушение приватности. Логируем только `{model, prompt_tokens, completion_tokens, duration_ms, status_code}`.
- **Не отменять `Task`** при закрытии view — утечка сетевых запросов. Используем `Task.isCancelled` и структурированную конкурентность.
- **Кешировать тела писем «для AI»** — запрещено политикой. Кешируем только `summary` по `hash(body)`.
- **Parse SSE вручную через split('\n')** — может сломаться на chunked boundaries. Используем `bytes.lines` (honored-BOM, корректный CRLF).
- **Отправлять BCC/CC/from в промпт** — утечка PII. Фильтруем заголовки.

## Промпт-инжиниринг (наш минимум)

- System message лаконичный, с явным запретом на галлюцинации.
- Few-shot примеры — если повторяющийся сценарий (суммаризация, rate importance), иначе экономим входные токены.
- Инструкция по языку: «отвечай на том же языке, что и входящее письмо».
- **Экранирование пользовательских данных в промпте**: тема письма может содержать `{{ }}` / command injection для самой модели — пока не критично, но помним.

## Кеш (по нашей политике)

- Ключ: `SHA-256(body_canonical)`.
- Значение: `summary_text` — хранится в `messages.summary_hash` / `messages.summary_text` (текст — да, он создан AI, не само письмо).
- При повторном запросе той же операции на то же тело — отдаём из БД, не идём в сеть.

## Ссылки

- Docs: https://openrouter.ai/docs
- Models: https://openrouter.ai/models
- Streaming: https://openrouter.ai/docs/api-reference/streaming
