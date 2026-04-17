#if canImport(XCTest)
import XCTest
@testable import MockData
import Core

final class MockAccountDataProviderTests: XCTestCase {
    func testMailboxes() async throws {
        let provider = MockAccountDataProvider()
        let mbs = try await provider.mailboxes()
        XCTAssertEqual(mbs.count, 3)
        XCTAssertTrue(mbs.contains { $0.role == .inbox })
        XCTAssertTrue(mbs.contains { $0.role == .sent })
        XCTAssertTrue(mbs.contains { $0.role == .archive })
    }

    func testMessagesPagination() async throws {
        let provider = MockAccountDataProvider()
        let inbox = try await provider.mailboxes().first { $0.role == .inbox }!
        var totalReceived = 0
        for try await page in provider.messages(in: inbox.id, page: .init(offset: 0, limit: 50)) {
            totalReceived += page.count
        }
        XCTAssertEqual(totalReceived, 50)
    }

    func testBodyStreams() async throws {
        let provider = MockAccountDataProvider()
        let inbox = try await provider.mailboxes().first { $0.role == .inbox }!
        var firstMessage: Message?
        for try await page in provider.messages(in: inbox.id, page: .init(offset: 0, limit: 1)) {
            firstMessage = page.first
        }
        let msg = try XCTUnwrap(firstMessage)
        var bytes: [UInt8] = []
        for try await chunk in provider.body(for: msg.id) {
            bytes.append(contentsOf: chunk.bytes)
        }
        XCTAssertGreaterThan(bytes.count, 0)
    }
}
#endif
