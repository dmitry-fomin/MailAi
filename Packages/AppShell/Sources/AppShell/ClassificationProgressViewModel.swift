import Foundation
import SwiftUI

/// AI-5: реактивная VM прогресс-бара классификации. Подписывается на
/// `ClassificationQueue.observe()` (AsyncStream<Snapshot>) и публикует
/// последний снапшот для UI.
///
/// Видимость прогресс-бара управляется флагом `isActive` — `true`,
/// если в очереди есть `pending` или `inFlight` элементы.
@MainActor
public final class ClassificationProgressViewModel: ObservableObject {
    @Published public private(set) var total: Int = 0
    @Published public private(set) var pending: Int = 0
    @Published public private(set) var inFlight: Int = 0
    @Published public private(set) var failed: Int = 0
    @Published public private(set) var isActive: Bool = false

    private var observerTask: Task<Void, Never>?

    public init() {}

    /// Подписаться на снапшоты очереди. Поддерживает безопасную замену
    /// очереди (старая подписка отменяется).
    ///
    /// Использует `observeAsync()` — регистрация observer происходит атомарно
    /// внутри актора, race condition отсутствует (исправлен MailAi-tze).
    public func bind(to queue: ClassificationQueue) {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            // observeAsync() вызывается изолированно внутри актора ClassificationQueue —
            // observer регистрируется до первого await, без race condition.
            let stream = await queue.observeAsync()
            for await snap in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    self.total = snap.total
                    self.pending = snap.pending
                    self.inFlight = snap.inFlight
                    self.failed = snap.failed
                    self.isActive = (snap.pending + snap.inFlight) > 0
                }
            }
        }
    }

    public func unbind() {
        observerTask?.cancel()
        observerTask = nil
        isActive = false
        total = 0
        pending = 0
        inFlight = 0
        failed = 0
    }

    /// Сколько обработано (для прогресс-бара).
    public var processed: Int {
        max(0, total - pending - inFlight)
    }

    deinit {
        observerTask?.cancel()
    }
}
