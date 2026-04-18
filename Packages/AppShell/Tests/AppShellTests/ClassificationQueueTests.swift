#if canImport(XCTest)
import XCTest
import Foundation
@testable import AppShell

final class ClassificationQueueTests: XCTestCase {

    func testEnqueueDeduplicates() async {
        let queue = ClassificationQueue(batchSize: 10, maxParallel: 1)
        await queue.enqueue(["a", "b", "a"])
        let s = await queue.snapshot()
        XCTAssertEqual(s.total, 2, "duplicates must be ignored")
        XCTAssertEqual(s.pending, 2)
    }

    func testProcessAllDrainsAndReportsZeroPending() async {
        let queue = ClassificationQueue(batchSize: 5, maxParallel: 2)
        await queue.enqueue(["1", "2", "3", "4", "5"])
        await queue.processAll { _ in
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let s = await queue.snapshot()
        XCTAssertEqual(s.pending, 0)
        XCTAssertEqual(s.inFlight, 0)
        XCTAssertEqual(s.failed, 0)
    }

    func testFailuresGoToFailed() async {
        let queue = ClassificationQueue(batchSize: 5, maxParallel: 1)
        await queue.enqueue(["ok", "fail", "ok2"])
        struct TestErr: Error {}
        await queue.processAll { id in
            if id == "fail" { throw TestErr() }
        }
        let s = await queue.snapshot()
        XCTAssertEqual(s.pending, 0)
        XCTAssertEqual(s.failed, 1)
    }

    func testObservationEmitsSnapshots() async {
        let queue = ClassificationQueue(batchSize: 5, maxParallel: 1)

        // Собираем snapshot'ы в фоне
        let collected: Task<[ClassificationQueue.Snapshot], Never> = Task {
            var out: [ClassificationQueue.Snapshot] = []
            for await snap in queue.observe() {
                out.append(snap)
                if snap.isIdle && snap.total > 0 { break }
            }
            return out
        }

        try? await Task.sleep(nanoseconds: 50_000_000)  // дать подписке установиться
        await queue.enqueue(["x", "y"])
        await queue.processAll { _ in
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let snaps = await collected.value
        XCTAssertFalse(snaps.isEmpty)
        XCTAssertTrue(snaps.contains(where: { $0.pending == 2 }))
        XCTAssertTrue(snaps.last?.isIdle ?? false)
    }

    func testResetClearsState() async {
        let queue = ClassificationQueue()
        await queue.enqueue(["a", "b"])
        await queue.reset()
        let s = await queue.snapshot()
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(s.pending, 0)
    }
}
#endif
