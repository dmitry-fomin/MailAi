import Foundation

/// Ошибка классификации с разделением на retryable / permanent.
/// 429 и 5xx — retryable (триггерят exponential backoff).
/// Всё остальное — permanent (fail без повторной попытки).
public enum ClassificationError: Error, Sendable, Equatable {
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int)
    case permanent(message: String)
}

extension ClassificationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .rateLimited(let after):
            return "rateLimited(retryAfter: \(after?.description ?? "nil"))"
        case .serverError(let code):
            return "serverError(\(code))"
        case .permanent(let msg):
            return "permanent(\(msg))"
        }
    }
}

/// Фоновая очередь классификации. Актор хранит список необработанных
/// `message.id`, публикует snapshot'ы для UI прогресс-бара и выполняет
/// работу батчами с ограниченной параллельностью.
///
/// Поддерживает два режима работы:
/// - `processAll` — по одному элементу (legacy), без retry.
/// - `processBatched` — батчами по `batchSize`, с exponential backoff
///   при 429/5xx (через `ClassificationError`).
///
/// Формула backoff: `baseRetryDelay * 2^retryCount`, макс. `maxRetryDelay` (60s).
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
    public let maxRetries: Int
    public let baseRetryDelay: TimeInterval

    /// Максимальная задержка между повторными попытками (секунды).
    public static let maxRetryDelay: TimeInterval = 60

    private var pending: [String] = []
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []
    private var total: Int = 0
    /// Счётчик повторных попыток для retryable-ошибок.
    private var retryCounts: [String: Int] = [:]
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public init(
        batchSize: Int = 10,
        maxParallel: Int = 3,
        maxRetries: Int = 3,
        baseRetryDelay: TimeInterval = 1.0
    ) {
        precondition(batchSize > 0 && maxParallel > 0 && maxRetries >= 0 && baseRetryDelay > 0)
        self.batchSize = batchSize
        self.maxParallel = maxParallel
        self.maxRetries = maxRetries
        self.baseRetryDelay = baseRetryDelay
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
        retryCounts.removeAll()
        total = 0
        broadcast()
    }

    /// Вычисляет задержку перед следующей попыткой для указанного retry count.
    public func retryDelay(forRetryCount count: Int) -> TimeInterval {
        let delay = baseRetryDelay * pow(2.0, Double(count))
        return min(delay, Self.maxRetryDelay)
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
    /// Legacy-метод: обрабатывает по одному элементу без retry.
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

    /// Обрабатывает очередь батчами. Каждый батч — до `batchSize` ID,
    /// передаваемых в `worker`. Worker возвращает per-ID результат:
    /// `nil` = успех, `ClassificationError` = ошибка.
    ///
    /// - При `.rateLimited` / `.serverError` — retry с exponential backoff.
    /// - При `.permanent` — fail без повторной попытки.
    /// - При достижении `maxRetries` — тоже fail.
    public func processBatched(
        batchSize: Int? = nil,
        worker: @Sendable @escaping ([String]) async throws -> [String: ClassificationError?]
    ) async {
        let size = batchSize ?? self.batchSize

        // Повторяем цикл, пока есть pending или ещё не все retry исчерпаны.
        while !pending.isEmpty {
            // 1. Берём батч из pending.
            let batch = popBatch(size)
            guard !batch.isEmpty else { break }

            // 2. Вызываем worker.
            let results: [String: ClassificationError?]
            do {
                results = try await worker(batch)
            } catch {
                // Worker целиком упал (не per-ID) — retry весь батч.
                for id in batch {
                    await handleRetryable(id: id, error: .permanent(message: String(describing: error)))
                }
                broadcast()
                continue
            }

            // 3. Обрабатываем per-ID результаты.
            for id in batch {
                inFlight.remove(id)

                if let errorOpt = results[id], let error = errorOpt {
                    switch error {
                    case .rateLimited, .serverError:
                        await handleRetryable(id: id, error: error)
                    case .permanent:
                        failed.insert(id)
                        retryCounts.removeValue(forKey: id)
                    }
                } else {
                    // Успех — очищаем retry-счётчик.
                    retryCounts.removeValue(forKey: id)
                }
            }
            broadcast()

            // 4. Если в pending ещё остались retryable-элементы — sleep до первой готовой.
            if !pending.isEmpty {
                let minDelay = pending.compactMap { retryCounts[$0].map { retryDelay(forRetryCount: $0) } }.min()
                if let delay = minDelay, delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    // MARK: - Batch Helpers

    /// Извлекает до `count` элементов из pending → inFlight.
    private func popBatch(_ count: Int) -> [String] {
        var batch: [String] = []
        let take = min(count, pending.count)
        for _ in 0..<take {
            let id = pending.removeFirst()
            inFlight.insert(id)
            batch.append(id)
        }
        broadcast()
        return batch
    }

    /// Обрабатывает retryable-ошибку: увеличивает счётчик, при превышении
    /// `maxRetries` — переводит в `failed`.
    private func handleRetryable(id: String, error: ClassificationError) {
        let count = (retryCounts[id] ?? -1) + 1
        if count >= maxRetries {
            failed.insert(id)
            retryCounts.removeValue(forKey: id)
        } else {
            retryCounts[id] = count
            pending.append(id)
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
