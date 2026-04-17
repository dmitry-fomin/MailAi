#if canImport(XCTest)
import XCTest
@testable import Secrets
import Core

final class InMemorySecretsStoreTests: XCTestCase {
    func testRoundTrip() async throws {
        let store = InMemorySecretsStore()
        let id = Account.ID("acc-1")
        try await store.setPassword("secret", forAccount: id)
        let got = try await store.password(forAccount: id)
        XCTAssertEqual(got, "secret")
        try await store.deletePassword(forAccount: id)
        let gone = try await store.password(forAccount: id)
        XCTAssertNil(gone)
    }
}
#endif
