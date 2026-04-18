#if canImport(XCTest)
import XCTest
import Foundation
import NIOCore
@testable import MailTransport

/// Опциональный live-тест реального IMAP over TLS. Skip, если не задано
/// `IMAP_LIVE_HOST` и `IMAP_LIVE_PORT`. Полезно, когда хочется проверить,
/// что мы получаем настоящий greeting от imap.gmail.com / imap.yandex.com
/// без авторизации.
final class IMAPLiveTLSTests: XCTestCase {

    func testGreetingFromLiveIMAPServer() async throws {
        let host = ProcessInfo.processInfo.environment["IMAP_LIVE_HOST"]
        let portStr = ProcessInfo.processInfo.environment["IMAP_LIVE_PORT"] ?? "993"
        try XCTSkipUnless(host != nil, "IMAP_LIVE_HOST not set — skipping live TLS test")
        guard let port = Int(portStr) else {
            XCTFail("IMAP_LIVE_PORT invalid")
            return
        }

        let endpoint = IMAPEndpoint(host: host!, port: port, security: .tls)
        let client = try await IMAPClientBootstrap.connect(
            to: endpoint,
            connectTimeout: .seconds(10)
        )
        try await client.executeThenClose { inbound, outbound in
            var iter = inbound.makeAsyncIterator()
            let greeting = try await iter.next()
            XCTAssertNotNil(greeting)
            XCTAssertTrue(
                greeting!.raw.hasPrefix("* OK") || greeting!.raw.hasPrefix("* PREAUTH"),
                "IMAP greeting should start with * OK or * PREAUTH, got: \(greeting!.raw)"
            )
            print("[live IMAP TLS] host=\(host!) greeting=\(greeting!.raw)")

            try await outbound.write(IMAPLine("a001 LOGOUT"))
            // Считываем пока не получим BYE или закрытие
            while let line = try await iter.next() {
                if line.raw.contains("BYE") || line.raw.contains("OK") { break }
            }
        }
    }
}
#endif
