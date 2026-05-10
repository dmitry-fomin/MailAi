import Foundation
import Core

/// Переводит текст писем через OpenRouter API.
///
/// Переведённый текст возвращается только в памяти — никогда не пишется на диск.
public actor OpenRouterTranslator: AITranslator {
    private let client: OpenRouterClient

    public init(client: OpenRouterClient) {
        self.client = client
    }

    /// Максимальное число символов тела письма, отправляемых в AI.
    /// Ограничивает расход токенов и соответствует privacy-требованиям.
    public static let maxBodyLength = 4_000

    /// Переводит `body` на указанный `targetLanguage`.
    ///
    /// Системный промпт загружается из `PromptStore` по идентификатору `"translate"`.
    /// Если промпт не найден — используется встроенный фоллбек.
    /// Тело письма усекается до `maxBodyLength` символов перед отправкой.
    public func translate(body: String, targetLanguage: String) async throws -> MailTranslation {
        let systemPrompt = await buildSystemPrompt(targetLanguage: targetLanguage)
        let truncatedBody = body.count > Self.maxBodyLength
            ? String(body.prefix(Self.maxBodyLength))
            : body

        var fullResponse = ""
        let stream = client.complete(system: systemPrompt, user: truncatedBody, streaming: false, maxTokens: 1_024)
        for try await chunk in stream {
            fullResponse += chunk
        }

        return MailTranslation(
            originalLanguage: nil,
            targetLanguage: targetLanguage,
            text: fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Private

    private func buildSystemPrompt(targetLanguage: String) async -> String {
        // Пробуем загрузить пользовательский/встроенный промпт.
        if let stored = try? await PromptStore.shared.load(id: "translate") {
            return stored.replacingOccurrences(of: "{{targetLanguage}}", with: targetLanguage)
        }
        // Встроенный фоллбек.
        return """
        You are a professional email translator. \
        Translate the following email text into \(targetLanguage). \
        Preserve formatting, tone, and structure. \
        Return only the translated text without any explanations or preamble.
        """
    }
}
