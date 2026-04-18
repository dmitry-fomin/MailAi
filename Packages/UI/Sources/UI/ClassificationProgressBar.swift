import SwiftUI

/// AI-pack v1 caркас: collapsed-слот прогресс-бара под header'ом списка писем.
/// В v1 всегда `isActive == false` → рендерит `EmptyView` (нулевая высота,
/// никаких визуальных артефактов). В AI-pack будет отображать прогресс
/// фоновой классификации: N / M писем.
///
/// Сохраняем отдельный View, чтобы интеграция AI-pack свелась к замене
/// constant → binding без перестройки иерархии AccountWindowScene.
public struct ClassificationProgressBar: View {
    public let isActive: Bool
    public let processed: Int
    public let total: Int

    public init(isActive: Bool = false, processed: Int = 0, total: Int = 0) {
        self.isActive = isActive
        self.processed = processed
        self.total = total
    }

    public var body: some View {
        if isActive && total > 0 {
            VStack(spacing: 4) {
                HStack {
                    Text("AI-классификация")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(processed)/\(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(processed), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(.opacity)
        } else {
            EmptyView()
        }
    }
}
