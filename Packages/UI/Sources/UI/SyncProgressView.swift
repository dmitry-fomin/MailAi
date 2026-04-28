import SwiftUI

// MARK: - SyncStatusIndicator

/// Компактный индикатор состояния синхронизации для тулбара или статусной строки.
///
/// Отображает:
/// - **Синхронизация** — вращающийся `ProgressView` + текст «Синхронизация…».
/// - **Ошибка** — иконка `exclamationmark.triangle` + короткий текст ошибки.
/// - **Idle / завершено** — скрыт (нулевой размер, не занимает место).
///
/// Пример интеграции в тулбар:
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .status) {
///         SyncStatusIndicator(phase: syncPhase)
///     }
/// }
/// ```
public struct SyncStatusIndicator: View {

    public enum Phase: Equatable {
        case idle
        case syncing
        case failed(message: String)
    }

    public let phase: Phase

    public init(phase: Phase) {
        self.phase = phase
    }

    public var body: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text("Синхронизация…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)

        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - SyncProgressViewModel

/// ViewModel для наблюдения за `AsyncStream<SyncProgress>` из `BackgroundSyncCoordinator`.
///
/// Подписывается на стрим в `Task` и публикует актуальную фазу на `@MainActor`.
/// Тип `SyncProgress` и `SyncProgress.Phase` живут в `AppShell`; здесь мы работаем
/// с `SyncStatusIndicator.Phase` — облегчённым зеркалом без зависимости от `AppShell`.
///
/// Использование:
/// ```swift
/// @StateObject private var syncVM = SyncProgressViewModel()
///
/// .onAppear {
///     syncVM.bind(to: coordinator.progress)
/// }
/// .toolbar {
///     ToolbarItem(placement: .status) {
///         SyncStatusIndicator(phase: syncVM.phase)
///     }
/// }
/// ```
@MainActor
public final class SyncProgressViewModel: ObservableObject {

    @Published public private(set) var phase: SyncStatusIndicator.Phase = .idle

    private var observerTask: Task<Void, Never>?

    public init() {}

    deinit {
        observerTask?.cancel()
    }

    /// Подписывается на стрим прогресса. Предыдущая подписка отменяется.
    ///
    /// - Parameter stream: `AsyncStream`, производящий элементы с двумя
    ///   обязательными свойствами: `phase` (enum) через маппинг.
    ///   Принимает замыкание-маппер, чтобы не зависеть от конкретного типа AppShell.
    public func bind<S: AsyncSequence & Sendable>(
        to stream: S,
        phaseMapper: @escaping @Sendable (S.Element) -> SyncStatusIndicator.Phase
    ) where S.Element: Sendable {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            do {
                for try await element in stream {
                    guard !Task.isCancelled else { break }
                    let mapped = phaseMapper(element)
                    await MainActor.run {
                        self?.phase = mapped
                    }
                }
            } catch {}
            await MainActor.run {
                self?.phase = .idle
            }
        }
    }

    /// Сбрасывает наблюдение и возвращает индикатор в `.idle`.
    public func unbind() {
        observerTask?.cancel()
        observerTask = nil
        phase = .idle
    }
}
