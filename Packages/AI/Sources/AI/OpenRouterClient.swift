import Foundation
import Core

/// HTTP-клиент OpenRouter с поддержкой SSE-стриминга. Реализует `AIProvider`.
///
/// Приватность:
/// - API-ключ передаётся извне (из `Secrets`/Keychain), в коде не живёт.
/// - Логгирование только технической телеметрии, содержимого промпта/ответа
///   клиент не логирует.
public struct OpenRouterClient: AIProvider, Sendable {
    public let apiKey: String
    public let model: String
    public let session: URLSession
    public let referer: String
    public let appTitle: String

    public init(
        apiKey: String,
        model: String,
        session: URLSession = .shared,
        referer: String = "https://mailai.app",
        appTitle: String = "MailAi"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.referer = referer
        self.appTitle = appTitle
    }

    public func complete(
        system: String,
        user: String,
        streaming: Bool
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(system: system, user: user, streaming: streaming)
                    if streaming {
                        try await runStreaming(request: request, continuation: continuation)
                    } else {
                        try await runSingle(request: request, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func buildRequest(system: String, user: String, streaming: Bool) throws -> URLRequest {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        req.setValue(appTitle, forHTTPHeaderField: "X-Title")
        req.timeoutInterval = 60

        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            stream: streaming,
            temperature: 0.2,
            maxTokens: 200
        )
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func runStreaming(
        request: URLRequest,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response)
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let delta = try? JSONDecoder().decode(StreamDelta.self, from: data),
                  let content = delta.choices.first?.delta.content,
                  !content.isEmpty else { continue }
            continuation.yield(content)
        }
    }

    private func runSingle(
        request: URLRequest,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let decoded = try JSONDecoder().decode(NonStreamResponse.self, from: data)
        if let content = decoded.choices.first?.message.content {
            continuation.yield(content)
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw OpenRouterError.unauthorized
        case 402: throw OpenRouterError.paymentRequired
        case 429: throw OpenRouterError.rateLimited
        case 500..<600: throw OpenRouterError.serverError(http.statusCode)
        default: throw OpenRouterError.httpError(http.statusCode)
        }
    }

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
}

public enum OpenRouterError: Error, Equatable, Sendable {
    case invalidResponse
    case unauthorized
    case paymentRequired
    case rateLimited
    case serverError(Int)
    case httpError(Int)
}

// MARK: - Wire types

struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
    }
}

struct StreamDelta: Decodable {
    let choices: [Choice]
    struct Choice: Decodable { let delta: Delta }
    struct Delta: Decodable { let content: String? }
}

struct NonStreamResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}
