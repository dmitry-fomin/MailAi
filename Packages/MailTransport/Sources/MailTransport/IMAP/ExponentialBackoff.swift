import Foundation

/// Экспоненциальный backoff для реконнектов (B8). Чистое значение, без
/// побочных эффектов — `nextDelay()` возвращает секунды и двигает
/// внутренний счётчик попыток. Максимум по умолчанию 60 с; jitter
/// размазывает групповые обрывы, чтобы не долбить сервер синхронно.
public struct ExponentialBackoff: Sendable {
    public let base: TimeInterval
    public let multiplier: Double
    public let maxDelay: TimeInterval
    public let jitter: Double
    public private(set) var attempt: Int

    public init(
        base: TimeInterval = 0.5,
        multiplier: Double = 2.0,
        maxDelay: TimeInterval = 60,
        jitter: Double = 0.2,
        attempt: Int = 0
    ) {
        self.base = base
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.attempt = attempt
    }

    /// Возвращает задержку перед следующей попыткой и увеличивает счётчик.
    /// Не уменьшается ниже нуля; `Retry-After` передаётся приоритетно, если
    /// сервер подсказал минимум.
    public mutating func nextDelay(
        respectRetryAfter: TimeInterval? = nil,
        randomFraction: Double = Double.random(in: 0..<1)
    ) -> TimeInterval {
        let exp = base * pow(multiplier, Double(attempt))
        attempt += 1
        let raw = min(exp, maxDelay)
        let jitterRange = raw * jitter
        let withJitter = raw + (randomFraction * 2 - 1) * jitterRange
        let clamped = max(0, withJitter)
        if let hint = respectRetryAfter, hint > clamped {
            return hint
        }
        return clamped
    }

    public mutating func reset() {
        attempt = 0
    }
}
