#if canImport(XCTest)
import XCTest
@testable import Storage
import Core

final class InMemoryMetadataStoreTests: XCTestCase {
    func testUpsertAndFetch() async throws {
        let store = InMemoryMetadataStore()
        let mailbox = Mailbox.ID("inbox")
        let msg = Message(
            id: .init("m-1"),
            accountID: .init("acc-1"),
            mailboxID: mailbox,
            uid: 1,
            messageID: nil,
            threadID: nil,
            subject: "s",
            from: nil,
            to: [],
            cc: [],
            date: Date(),
            preview: nil,
            size: 0,
            flags: [],
            importance: .unknown
        )
        try await store.upsert([msg])
        let got = try await store.messages(in: mailbox, page: .init(offset: 0, limit: 10))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.id, .init("m-1"))
    }
}
#endif
