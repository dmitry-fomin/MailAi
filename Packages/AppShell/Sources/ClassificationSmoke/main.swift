import Foundation
import AppShell

private actor Box<T: Sendable> {
    var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { value = newValue }
    func mutate(_ f: (inout T) -> Void) { f(&value) }
}

/// Smoke test для ClassificationQueue: батчинг, retry при 429, permanent fail.
@main
enum ClassificationSmokeRunner {
    static func main() async throws {
        func check(_ label: String, _ condition: Bool) {
            guard condition else {
                FileHandle.standardError.write(Data("✘ \(label)\n".utf8))
                exit(1)
            }
            print("✓ \(label)")
        }

        // ── Test 1: Батчинг группирует правильно ─────────────────────────
        // Создаём очередь с batchSize=3, enqueue 7 items.
        // Worker получит: [0,1,2], [3,4,5], [6].
        do {
            let queue = ClassificationQueue(
                batchSize: 3,
                maxParallel: 3,
                maxRetries: 0,
                baseRetryDelay: 0.01
            )

            let ids = (0..<7).map { "msg-\($0)" }
            await queue.enqueue(ids)

            let batchesBox = Box<[[String]]>([])

            await queue.processBatched { batch in
                await batchesBox.mutate { $0.append(batch) }
                // Все успешны.
                return batch.reduce(into: [String: ClassificationError?]()) { result, id in
                    result[id] = nil
                }
            }

            let batches = await batchesBox.value
            check("Batching: 3 батча для 7 элементов (3+3+1)", batches.count == 3)
            check("Batching: 1-й батч = 3 элемента", batches[0].count == 3)
            check("Batching: 2-й батч = 3 элемента", batches[1].count == 3)
            check("Batching: 3-й батч = 1 элемент", batches[2].count == 1)

            let snap = await queue.snapshot()
            check("Batching: очередь пуста после обработки", snap.isIdle)
            check("Batching: 0 failed", snap.failed == 0)
        }

        // ── Test 2: Retry при rate-limited (429) ─────────────────────────
        // Элемент "retry-me" сначала возвращает 429, потом успех.
        do {
            let queue = ClassificationQueue(
                batchSize: 5,
                maxParallel: 3,
                maxRetries: 3,
                baseRetryDelay: 0.01
            )

            let ids = ["ok-1", "ok-2", "retry-me", "ok-3"]
            await queue.enqueue(ids)

            let attemptBox = Box<Int>(0)

            await queue.processBatched { batch in
                let currentAttempt = await attemptBox.value
                var results: [String: ClassificationError?] = [:]
                for id in batch {
                    if id == "retry-me" && currentAttempt < 2 {
                        // Первые 2 попытки — rate limited.
                        results[id] = .rateLimited(retryAfter: nil)
                    } else {
                        results[id] = nil
                    }
                }
                await attemptBox.mutate { $0 += 1 }
                return results
            }

            let attempt = await attemptBox.value
            let snap = await queue.snapshot()
            check("Retry: очередь пуста", snap.isIdle)
            check("Retry: 0 failed (retry-me в конце прошёл)", snap.failed == 0)
            check("Retry: было ≥2 попытки", attempt >= 2)
        }

        // ── Test 3: Permanent error → fail без retry ─────────────────────
        do {
            let queue = ClassificationQueue(
                batchSize: 5,
                maxParallel: 3,
                maxRetries: 3,
                baseRetryDelay: 0.01
            )

            let ids = ["good-1", "bad-perm", "good-2"]
            await queue.enqueue(ids)

            let batchCountBox = Box<Int>(0)

            await queue.processBatched { batch in
                await batchCountBox.mutate { $0 += 1 }
                var results: [String: ClassificationError?] = [:]
                for id in batch {
                    if id == "bad-perm" {
                        results[id] = .permanent(message: "test error")
                    } else {
                        results[id] = nil
                    }
                }
                return results
            }

            let batchCount = await batchCountBox.value
            let snap = await queue.snapshot()
            check("Permanent: pending = 0", snap.pending == 0)
            check("Permanent: 1 failed (bad-perm)", snap.failed == 1)
            check("Permanent: 1 батч (нет retry)", batchCount == 1)
        }

        // ── Test 4: serverError (5xx) тоже retryable ─────────────────────
        do {
            let queue = ClassificationQueue(
                batchSize: 5,
                maxParallel: 3,
                maxRetries: 2,
                baseRetryDelay: 0.01
            )

            await queue.enqueue(["five-oh-oh"])

            let attemptsBox = Box<Int>(0)

            await queue.processBatched { batch in
                await attemptsBox.mutate { $0 += 1 }
                let currentAttempts = await attemptsBox.value
                var results: [String: ClassificationError?] = [:]
                for id in batch {
                    if currentAttempts <= 1 {
                        results[id] = .serverError(statusCode: 503)
                    } else {
                        results[id] = nil
                    }
                }
                return results
            }

            let attempts = await attemptsBox.value
            let snap = await queue.snapshot()
            check("5xx retry: очередь пуста", snap.isIdle)
            check("5xx retry: 2 попытки", attempts == 2)
        }

        // ── Test 5: maxRetries исчерпан → fail ───────────────────────────
        do {
            let queue = ClassificationQueue(
                batchSize: 5,
                maxParallel: 3,
                maxRetries: 2,
                baseRetryDelay: 0.01
            )

            await queue.enqueue(["always-429"])

            await queue.processBatched { batch in
                var results: [String: ClassificationError?] = [:]
                for id in batch {
                    results[id] = .rateLimited(retryAfter: nil)
                }
                return results
            }

            let snap = await queue.snapshot()
            check("MaxRetries: 1 failed", snap.failed == 1)
            check("MaxRetries: pending = 0", snap.pending == 0)
        }

        // ── Test 6: Backoff формула ───────────────────────────────────────
        do {
            let queue = ClassificationQueue(
                batchSize: 1,
                maxParallel: 1,
                maxRetries: 5,
                baseRetryDelay: 2.0
            )

            let d0 = await queue.retryDelay(forRetryCount: 0)
            let d1 = await queue.retryDelay(forRetryCount: 1)
            let d2 = await queue.retryDelay(forRetryCount: 2)
            let d3 = await queue.retryDelay(forRetryCount: 3)

            check("Backoff: retry 0 → 2.0s", d0 == 2.0)
            check("Backoff: retry 1 → 4.0s", d1 == 4.0)
            check("Backoff: retry 2 → 8.0s", d2 == 8.0)
            check("Backoff: retry 3 → 16.0s", d3 == 16.0)

            let d10 = await queue.retryDelay(forRetryCount: 10)
            check("Backoff: capped at 60s", d10 == 60.0)
        }

        print("\nAll ClassificationQueue smoke checks passed.")
    }
}
