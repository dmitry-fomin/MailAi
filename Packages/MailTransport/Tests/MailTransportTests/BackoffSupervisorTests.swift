#if canImport(XCTest)
import XCTest
@testable import MailTransport

final class ExponentialBackoffTests: XCTestCase {
    func testGrowsExponentially() {
        var b = ExponentialBackoff(base: 1, multiplier: 2, maxDelay: 100, jitter: 0)
        let d1 = b.nextDelay(randomFraction: 0.5)
        let d2 = b.nextDelay(randomFraction: 0.5)
        let d3 = b.nextDelay(randomFraction: 0.5)
        XCTAssertEqual(d1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(d2, 2.0, accuracy: 0.0001)
        XCTAssertEqual(d3, 4.0, accuracy: 0.0001)
    }

    func testRespectsMaxDelay() {
        var b = ExponentialBackoff(base: 1, multiplier: 10, maxDelay: 5, jitter: 0)
        _ = b.nextDelay(randomFraction: 0.5)
        _ = b.nextDelay(randomFraction: 0.5)
        XCTAssertEqual(b.nextDelay(randomFraction: 0.5), 5.0, accuracy: 0.0001)
        XCTAssertEqual(b.nextDelay(randomFraction: 0.5), 5.0, accuracy: 0.0001)
    }

    func testResetGoesBackToBase() {
        var b = ExponentialBackoff(base: 1, multiplier: 2, maxDelay: 100, jitter: 0)
        _ = b.nextDelay(randomFraction: 0.5)
        _ = b.nextDelay(randomFraction: 0.5)
        b.reset()
        XCTAssertEqual(b.nextDelay(randomFraction: 0.5), 1.0, accuracy: 0.0001)
    }

    func testRetryAfterOverridesWhenLarger() {
        var b = ExponentialBackoff(base: 1, multiplier: 2, maxDelay: 100, jitter: 0)
        let delay = b.nextDelay(respectRetryAfter: 30, randomFraction: 0.5)
        XCTAssertEqual(delay, 30, accuracy: 0.0001)
    }

    func testRetryAfterIgnoredWhenSmaller() {
        var b = ExponentialBackoff(base: 10, multiplier: 2, maxDelay: 100, jitter: 0)
        let delay = b.nextDelay(respectRetryAfter: 1, randomFraction: 0.5)
        XCTAssertEqual(delay, 10, accuracy: 0.0001)
    }

    func testJitterWithinBand() {
        var b = ExponentialBackoff(base: 10, multiplier: 1, maxDelay: 100, jitter: 0.5)
        // randomFraction=0 → минимум = 10 - 10*0.5 = 5
        var c = b
        XCTAssertEqual(c.nextDelay(randomFraction: 0.0), 5, accuracy: 0.0001)
        // randomFraction=1 → максимум = 10 + 10*0.5 = 15
        c = b
        XCTAssertEqual(c.nextDelay(randomFraction: 1.0), 15, accuracy: 0.0001)
    }
}

final class IMAPReconnectSupervisorTests: XCTestCase {
    struct TempError: Error {}
    struct FatalError: Error {}

    func testReturnsResultOnFirstSuccess() async throws {
        let supervisor = IMAPReconnectSupervisor(
            backoff: ExponentialBackoff(base: 0.001, multiplier: 1, maxDelay: 0.01, jitter: 0)
        )
        let value = try await supervisor.run(operation: { 42 })
        XCTAssertEqual(value, 42)
    }

    func testRetriesUntilSuccess() async throws {
        let supervisor = IMAPReconnectSupervisor(
            backoff: ExponentialBackoff(base: 0.001, multiplier: 1, maxDelay: 0.01, jitter: 0)
        )
        let counter = Counter()
        let value = try await supervisor.run(operation: {
            let n = await counter.increment()
            if n < 3 { throw TempError() }
            return n
        })
        XCTAssertEqual(value, 3)
    }

    func testRespectsMaxAttempts() async {
        let supervisor = IMAPReconnectSupervisor(
            backoff: ExponentialBackoff(base: 0.001, multiplier: 1, maxDelay: 0.01, jitter: 0)
        )
        do {
            _ = try await supervisor.run(maxAttempts: 2, operation: { () async throws -> Int in
                throw TempError()
            })
            XCTFail("должно было бросить")
        } catch is TempError {
            // ok
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    func testShouldRetryFalseStopsImmediately() async {
        let supervisor = IMAPReconnectSupervisor(
            backoff: ExponentialBackoff(base: 0.001, multiplier: 1, maxDelay: 0.01, jitter: 0)
        )
        let counter = Counter()
        do {
            _ = try await supervisor.run(
                shouldRetry: { _ in false },
                operation: { () async throws -> Int in
                    _ = await counter.increment()
                    throw FatalError()
                }
            )
            XCTFail("должно было бросить")
        } catch is FatalError {
            let n = await counter.value
            XCTAssertEqual(n, 1, "операция должна была выполниться ровно один раз")
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    private actor Counter {
        var value: Int = 0
        func increment() -> Int { value += 1; return value }
    }
}
#endif
