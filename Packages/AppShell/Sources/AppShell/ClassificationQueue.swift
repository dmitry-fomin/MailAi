import Foundation

/// Фоновая очередь классификации. Актор хранит список необработанных
/// `message.id`, публикует snapshot'ы для UI прогресс-бара и выполняет
/// работу батчами с ограниченной параллельностью.
///
/// Ошибки помечают запись как `failed`, но сам задач из очереди не возвращает —
/// повторную попытку можно запланировать через `enqueue(retryFailed: true)`.
public actor ClassificationQueue {
    public struct Snapshot: Sendable, Equatable {
        public let total: Int
        public let pending: Int
        public let failed: Int
        public let inFlight: Int

        public var isIdle: Bool { pending == 0 && inFlight == 0 }
    }

    public let batchSize: Int
    public let maxParallel: Int

    private var pending: [String] = []
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []
    private var total: Int = 0
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public init(batchSize: Int = 10, maxParallel: Int = 3) {
        precondition(batchSize > 0 && maxParallel > 0)
        self.batchSize = batchSize
        self.maxParallel = maxParallel
    }

    // MARK: - Enqueue

    public func enqueue(_ ids: [String]) {
        var seen: Set<String> = Set(pending).union(inFlight)
        var added: [String] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            added.append(id)
        }
        pending.append(contentsOf: added)
        total += added.count
        broadcast()
    }

    public func retryFailed() {
        let retry = Array(failed)
        failed.removeAll()
        enqueue(retry)
    }

    public func reset() {
        pending.removeAll()
        inFlight.removeAll()
        failed.removeAll()
        total = 0
        broadcast()
    }

    // MARK: - Snapshot + observation

    public func snapshot() -> Snapshot {
        Snapshot(total: total, pending: pending.count,
                 failed: failed.count, inFlight: inFlight.count)
    }

    public nonisolated func observe() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addObserver(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id: id) }
            }
        }
    }

    private func addObserver(id: UUID, continuation: AsyncStream<Snapshot>.Continuation) {
        continuations[id] = continuation
        continuation.yield(snapshot())
    }

    private func removeObserver(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast() {
        let s = snapshot()
        for c in continuations.values { c.yield(s) }
    }

    // MARK: - Processing

    /// Проходит по всем `pending`-элементам, вызывая `worker` для каждого.
    /// Максимум `maxParallel` одновременных выполнений.
    public func processAll(_ worker: @Sendable @escaping (String) async throws -> Void) async {
        await withTaskGroup(of: (String, Bool).self) { group in
            var active = 0
            while !pending.isEmpty || active > 0 {
                while active < maxParallel, let id = popNext() {
                    active += 1
                    group.addTask { [id] in
                        do {
                            try await worker(id)
                            return (id, true)
                        } catch {
                            return (id, false)
                        }
                    }
                }
                if let finished = await group.next() {
                    active -= 1
                    mark(id: finished.0, success: finished.1)
                }
            }
        }
    }

    private func popNext() -> String? {
        guard !pending.isEmpty else { return nil }
        let id = pending.removeFirst()
        inFlight.insert(id)
        broadcast()
        return id
    }

    private func mark(id: String, success: Bool) {
        inFlight.remove(id)
        if !success { failed.insert(id) }
        broadcast()
    }
}
