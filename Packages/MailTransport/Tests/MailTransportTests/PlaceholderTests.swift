#if canImport(XCTest)
import XCTest
@testable import MailTransport
import Core

final class LiveAccountDataProviderTests: XCTestCase {
    func testMailboxesThrowsUnsupportedStub() async {
        let account = Account(
            id: .init("a"), email: "x@y", displayName: nil,
            kind: .imap, host: "imap.example.com", port: 993,
            security: .tls, username: "x@y"
        )
        let provider = LiveAccountDataProvider(account: account)
        do {
            _ = try await provider.mailboxes()
            XCTFail("ожидали исключение")
        } catch let err as MailError {
            if case .unsupported = err {} else { XCTFail("wrong error: \(err)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
#endif
