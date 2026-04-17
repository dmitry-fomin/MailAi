#if canImport(XCTest)
import XCTest
@testable import Core

final class CoreModelsTests: XCTestCase {
    func testAccountCodableRoundTrip() throws {
        let account = Account(
            id: .init("acc-1"),
            email: "user@example.com",
            displayName: "User",
            kind: .imap,
            host: "imap.example.com",
            port: 993,
            security: .tls,
            username: "user@example.com"
        )
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(decoded, account)
    }

    func testMessageFlagsOptionSet() {
        let flags: MessageFlags = [.seen, .flagged, .hasAttachment]
        XCTAssertTrue(flags.contains(.seen))
        XCTAssertTrue(flags.contains(.flagged))
        XCTAssertFalse(flags.contains(.deleted))
        XCTAssertTrue(flags.contains(.hasAttachment))
    }

    func testMailboxInitialState() {
        let inbox = Mailbox(
            id: .init("mb-inbox"),
            accountID: .init("acc-1"),
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            unreadCount: 5,
            totalCount: 100,
            uidValidity: 42
        )
        XCTAssertTrue(inbox.children.isEmpty)
        XCTAssertEqual(inbox.role, .inbox)
        XCTAssertEqual(inbox.unreadCount, 5)
    }

    func testMailErrorLocalizedDescriptionNoPII() {
        let err = MailError.authentication(.invalidCredentials)
        let msg = err.localizedDescription
        XCTAssertFalse(msg.isEmpty)
        XCTAssertFalse(msg.contains("@"))
        XCTAssertFalse(msg.contains("password"))
    }

    func testImportanceDefaultIsUnknown() {
        XCTAssertTrue(Importance.allCases.contains(.unknown))
    }

    func testMessageThreadReferencesMessages() {
        let thread = MessageThread(
            id: .init("t-1"),
            accountID: .init("acc-1"),
            subject: "Re: hello",
            messageIDs: [.init("m-1"), .init("m-2")],
            lastDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(thread.messageIDs.count, 2)
    }
}
#endif
