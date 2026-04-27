import Foundation

/// Абстракция AI-клиента. Реализуется в `AI/OpenRouterClient`. UI, Classifier
/// и другие сценарии зависят только от этого протокола → легко мокируется.
public protocol AIProvider: Sendable {
    /// Делает chat-completion запрос к AI. Если `streaming == true`, отдаёт
    /// дельты по мере поступления. Если `false`, отдаёт один чанк с полным
    /// ответом.
    func complete(
        system: String,
        user: String,
        streaming: Bool
    ) -> AsyncThrowingStream<String, any Error>
}

// MARK: - Translation

/// Результат перевода письма. Живёт только в @State UI — никогда не пишется на диск.
public struct MailTranslation: Sendable {
    /// Язык оригинала (если удалось определить), иначе nil.
    public let originalLanguage: String?
    /// Целевой язык перевода (например "ru", "en").
    public let targetLanguage: String
    /// Переведённый текст.
    public let text: String

    public init(originalLanguage: String?, targetLanguage: String, text: String) {
        self.originalLanguage = originalLanguage
        self.targetLanguage = targetLanguage
        self.text = text
    }
}

/// Абстракция AI-переводчика. Реализуется в `AI/OpenRouterTranslator`.
public protocol AITranslator: Actor {
    /// Переводит текст на указанный язык.
    /// - Parameters:
    ///   - body: Текст письма (только в памяти, не сохраняется).
    ///   - targetLanguage: Язык назначения (IETF-тег: "ru", "en" и т.д.).
    func translate(body: String, targetLanguage: String) async throws -> MailTranslation
}
