import Foundation

/// Супервайзер, который выполняет `operation` с экспоненциальным backoff
/// при обрывах. Применяется поверх IDLE-циклов: каждый обрыв IMAP-сессии
/// (или reconnect-достойная ошибка) → пауза → новый запуск.
public actor IMAPReconnectSupervisor {
    public private(set) var backoff: ExponentialBackoff
    public var clock: any Clock<Duration> = ContinuousClock()

    public init(backoff: ExponentialBackoff = ExponentialBackoff()) {
        self.backoff = backoff
    }

    /// Запускает `operation` в бесконечном цикле до `maxAttempts` (nil — без
    /// лимита). При успешном возврате — сбрасывает backoff. При ошибке —
    /// вычисляет задержку и ждёт. Если передан `shouldRetry`, супервайзер
    /// использует его для решения о повторе (по умолчанию — ретраим всё,
    /// кроме `CancellationError`).
    public func run<Result: Sendable>(
        maxAttempts: Int? = nil,
        shouldRetry: @Sendable (any Error) -> Bool = defaultShouldRetry,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        var attempts = 0
        while true {
            attempts += 1
            do {
                let result = try await operation()
                backoff.reset()
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !shouldRetry(error) { throw error }
                if let limit = maxAttempts, attempts >= limit { throw error }
                let delay = backoff.nextDelay(respectRetryAfter: retryAfterHint(error))
                try await clock.sleep(for: .seconds(delay))
            }
        }
    }

    /// Подсказка Retry-After из ошибки. Расширяемо — добавляем свой enum.
    public static func retryAfterHint(_ error: any Error) -> TimeInterval? {
        if let hinted = error as? any HasRetryAfter {
            return hinted.retryAfter
        }
        return nil
    }

    private func retryAfterHint(_ error: any Error) -> TimeInterval? {
        Self.retryAfterHint(error)
    }

    public static let defaultShouldRetry: @Sendable (any Error) -> Bool = { error in
        // Отмену не ретраим — пусть подъедет CancellationError в stack.
        return !(error is CancellationError)
    }
}

/// Маркер ошибок, знающих о Retry-After (секундах до следующей попытки).
public protocol HasRetryAfter {
    var retryAfter: TimeInterval { get }
}
