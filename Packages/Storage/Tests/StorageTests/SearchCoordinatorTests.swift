#if canImport(XCTest)
import XCTest
import Foundation
import Core
@testable import Storage

// MARK: - Mocks

private actor MockLocalSearch: SearchService {
    var results: [Message]
    var callCount = 0

    init(results: [Message] = []) {
        self.results = results
    }

    func search(
        rawQuery: String,
        accountID: Account.ID,
        mailboxID: Mailbox.ID?,
        limit: Int
    ) async throws -> [Message] {
        callCount += 1
        return results
    }
}

private actor MockServerSearch: ServerSearchProvider {
    var results: [Message]
    var callCount = 0

    init(results: [Message] = []) {
        self.results = results
    }

    func serverSearch(
        query: String,
        mailboxID: Mailbox.ID?,
        accountID: Account.ID,
        limit: Int
    ) async throws -> [Message] {
        callCount += 1
        return results
    }
}

// MARK: - Helpers

private func makeMessage(id: String = "msg-1", accountID: Account.ID = .init("acc-1")) -> Message {
    Message(
        id: .init(id),
        accountID: accountID,
        mailboxID: .init("mb-1"),
        uid: 1,
        messageID: nil,
        threadID: nil,
        subject: "Test",
        from: nil,
        to: [],
        cc: [],
        date: Date(),
        preview: nil,
        size: 100,
        flags: [],
        importance: .unknown
    )
}

// MARK: - Tests

final class SearchCoordinatorTests: XCTestCase {

    func testLocalResultsReturnedWhenNonEmpty() async throws {
        let msg = makeMessage()
        let local = MockLocalSearch(results: [msg])
        let remote = MockServerSearch(results: [makeMessage(id: "server-msg")])
        let coordinator = SearchCoordinator(local: local, remote: remote)

        let results = try await coordinator.search(
            rawQuery: "test",
            accountID: .init("acc-1"),
            mailboxID: nil,
            limit: 10
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, msg.id)

        // Серверный поиск не должен быть вызван
        let remoteCallCount = await remote.callCount
        XCTAssertEqual(remoteCallCount, 0)
    }

    func testServerSearchCalledWhenLocalReturnsEmpty() async throws {
        let serverMsg = makeMessage(id: "server-msg")
        let local = MockLocalSearch(results: [])
        let remote = MockServerSearch(results: [serverMsg])
        let coordinator = SearchCoordinator(local: local, remote: remote)

        let results = try await coordinator.search(
            rawQuery: "test",
            accountID: .init("acc-1"),
            mailboxID: nil,
            limit: 10
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, serverMsg.id)

        let remoteCallCount = await remote.callCount
        XCTAssertEqual(remoteCallCount, 1)
    }

    func testEmptyResultsWhenNoRemoteAndLocalEmpty() async throws {
        let local = MockLocalSearch(results: [])
        let coordinator = SearchCoordinator(local: local, remote: nil)

        let results = try await coordinator.search(
            rawQuery: "test",
            accountID: .init("acc-1"),
            mailboxID: nil,
            limit: 10
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testLocalCallCountIsAlwaysOne() async throws {
        let local = MockLocalSearch(results: [makeMessage()])
        let coordinator = SearchCoordinator(local: local, remote: nil)

        _ = try await coordinator.search(
            rawQuery: "hello",
            accountID: .init("acc-1"),
            mailboxID: .init("mb-1"),
            limit: 50
        )

        let localCallCount = await local.callCount
        XCTAssertEqual(localCallCount, 1)
    }
}
#endif
