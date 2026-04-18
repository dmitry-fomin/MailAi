#if canImport(XCTest)
import XCTest
@testable import AppShell

final class UndoStackTests: XCTestCase {

    func testPushAndPop() async {
        let stack = UndoStack(capacity: 5)
        await stack.push(.move(messageIDs: ["m1"], from: "INBOX", to: "Trash"))
        let popped = await stack.pop()
        XCTAssertNotNil(popped)
        if case .move(let ids, let from, let to) = popped {
            XCTAssertEqual(ids, ["m1"])
            XCTAssertEqual(from, "INBOX")
            XCTAssertEqual(to, "Trash")
        } else {
            XCTFail("Expected .move action")
        }
    }

    func testPopOnEmptyReturnsNil() async {
        let stack = UndoStack(capacity: 5)
        let popped = await stack.pop()
        XCTAssertNil(popped)
    }

    func testLIFOOrder() async {
        let stack = UndoStack(capacity: 10)
        for i in 0..<3 {
            await stack.push(.move(messageIDs: ["m\(i)"], from: "a", to: "b"))
        }
        var seen: [String] = []
        while let action = await stack.pop() {
            if case .move(let ids, _, _) = action {
                seen.append(ids.first!)
            }
        }
        XCTAssertEqual(seen, ["m2", "m1", "m0"])
    }

    func testCapacityCap() async {
        let stack = UndoStack(capacity: 3)
        for i in 0..<5 {
            await stack.push(.move(messageIDs: ["m\(i)"], from: "a", to: "b"))
        }
        let count = await stack.count
        XCTAssertEqual(count, 3)
        // Должны остаться последние 3: m2, m3, m4
        let snapshot = await stack.snapshot()
        let ids = snapshot.compactMap { action -> String? in
            if case .move(let ids, _, _) = action { return ids.first }
            return nil
        }
        XCTAssertEqual(ids, ["m2", "m3", "m4"])
    }

    func testClear() async {
        let stack = UndoStack(capacity: 5)
        for i in 0..<3 {
            await stack.push(.move(messageIDs: ["m\(i)"], from: "a", to: "b"))
        }
        await stack.clear()
        let count = await stack.count
        XCTAssertEqual(count, 0)
    }
}
#endif
