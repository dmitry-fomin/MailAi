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
