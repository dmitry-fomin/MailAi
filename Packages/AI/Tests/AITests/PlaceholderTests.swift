#if canImport(XCTest)
import XCTest
@testable import AI
import Core

final class NoOpAIClassifierTests: XCTestCase {
    func testImportanceIsUnknown() async throws {
        let cls = NoOpAIClassifier()
        let msg = Message(
            id: .init("m"), accountID: .init("a"), mailboxID: .init("mb"),
            uid: 1, messageID: nil, threadID: nil, subject: "", from: nil,
            to: [], cc: [], date: Date(), preview: nil, size: 0,
            flags: [], importance: .unknown
        )
        let imp = try await cls.importance(for: msg)
        XCTAssertEqual(imp, .unknown)
    }
}
#endif
