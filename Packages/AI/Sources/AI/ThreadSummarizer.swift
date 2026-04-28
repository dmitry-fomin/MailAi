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
        return provider.complete(
            system: Self.systemPrompt,
            user: userPrompt,
            streaming: true,
            maxTokens: 512
        )
    }

    // MARK: - Private

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

    private static let systemPrompt = """
        You are an email thread summarizer. Given a sequence of email messages, respond with a JSON object with this structure:
        {"summary": "2-3 sentence summary of the thread", "participants": ["address1", "address2"], "keyPoints": ["point 1", "point 2"]}
        Be concise. Respond only with valid JSON, no markdown, no explanation.
        """
}
