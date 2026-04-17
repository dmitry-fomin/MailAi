#if canImport(XCTest)
import XCTest
@testable import AppShell
import Core
import MockData

final class AppShellFactoryTests: XCTestCase {
    func testMockModeReturnsMockProvider() async throws {
        let account = Account(
            id: .init("a"), email: "x@y", displayName: nil,
            kind: .imap, host: "h", port: 1, security: .tls, username: "u"
        )
        let provider = AccountDataProviderFactory.make(for: account, mode: .mock)
        let mbs = try await provider.mailboxes()
        XCTAssertFalse(mbs.isEmpty)
    }
}
#endif
