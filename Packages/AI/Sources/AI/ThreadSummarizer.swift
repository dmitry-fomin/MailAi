import Foundation
import Core

/// AI-суммаризатор треда. Анализирует до 10 писем и возвращает
/// 2–3 предложения summary + ключевые пункты.
///
/// Приватность:
/// - Отправка происходит только по явному клику пользователя.
/// - Тела писем не сохраняются: только snippet 300 символов в памяти.
public actor ThreadSummarizer: AISummarizer {
    private let provider: any AIProvider
    private var cachedSystemPrompt: String?

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    /// Суммаризирует тред, возвращая streaming-ответ.
    /// Клиент собирает дельты в строку и разбирает результат самостоятельно.
    public func summarize(
        inputs: [MessageSummaryInput]
    ) -> AsyncThrowingStream<String, any Error> {
        let capped = Array(inputs.prefix(10))
        let userPrompt = buildUserPrompt(inputs: capped)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let system = try await self.resolveSystemPrompt()
                    for try await chunk in self.provider.complete(
                        system: system,
                        user: userPrompt,
                        streaming: true,
                        maxTokens: 512
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func resolveSystemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }
        let instruction = try await PromptStore.shared.load(id: "summarize")
        let full = instruction + "\n\n" + Self.responseFormat
        cachedSystemPrompt = full
        return full
    }

    private static let responseFormat = """
        Respond only with valid JSON, no markdown, no explanation:
        {"summary": "2-3 sentence summary of the thread", "participants": ["address1", "address2"], "keyPoints": ["point 1", "point 2"]}
        """

    private func buildUserPrompt(inputs: [MessageSummaryInput]) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let messages = inputs.enumerated().map { (i, input) in
            """
            Message \(i + 1):
            From: \(input.from)
            Date: \(dateFormatter.string(from: input.date))
            Body: \(input.bodySnippet)
            """
        }.joined(separator: "\n\n")
        return messages
    }
}
