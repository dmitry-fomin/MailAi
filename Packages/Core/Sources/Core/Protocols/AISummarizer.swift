import Foundation

/// Абстракция AI-суммаризатора треда. Реализуется в `AI/ThreadSummarizer`.
public protocol AISummarizer: Actor {
    /// Суммаризирует тред из до 10 писем.
    /// - Parameter inputs: Входные данные писем (до 10 штук).
    /// - Returns: Результат суммаризации, стримится по мере генерации.
    func summarize(
        inputs: [MessageSummaryInput]
    ) -> AsyncThrowingStream<String, any Error>
}
