// SMTP-6: end-to-end smoke для Compose-pipeline.
//
// 1. Happy-path SMTP — поднимает `FakeSMTPServer` (acceptAll), прогоняет
//    `LiveSendProvider.send(envelope:body:)` и проверяет, что fake получил
//    EHLO/AUTH/MAIL FROM/RCPT TO/DATA с корректными заголовками и QP-телом.
// 2. Failure-path SMTP — fake отвечает 550 на RCPT TO; провайдер должен
//    бросить `MailError`/`SMTPError.relay`.
// 3. Happy-path IMAP APPEND — поднимает `FakeIMAPServer`, прогоняет
//    `LiveAccountDataProvider.saveDraft(...)` и проверяет, что в Drafts
//    положен литерал с ожидаемыми Subject/From/To.
//
// Без TLS, без креденшелов, без сетевых вызовов — всё на 127.0.0.1.

import Foundation
import Core
import Secrets
import MailTransport
import NIOCore
import NIOPosix
#if canImport(Darwin)
import Darwin
#endif

// Stdout по умолчанию line-buffered в TTY и block-buffered в pipe.
// Принудительно отключаем буферизацию, чтобы Scripts/smoke.sh видел вывод
// сразу (важно, если smoke зависает — иначе получим пустой stdout).
private let _setvbufOnce: Void = {
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IOLBF, 0)
}()

func say(_ message: String) {
    _ = _setvbufOnce
    print(message)
}

func die(_ message: String) -> Never {
    say("✘ \(message)")
    exit(1)
}

func check(_ label: String, _ condition: Bool) {
    guard condition else { die(label) }
    say("✓ \(label)")
}

// MARK: - Account/endpoint helpers

func makeSMTPAccount(port: Int) -> Account {
    Account(
        id: Account.ID("smoke-smtp-\(UUID().uuidString)"),
        email: "alice@example.com",
        displayName: "Alice",
        kind: .imap,
        host: "127.0.0.1",
        port: 1, // не используется в SMTP-сценариях
        security: .none,
        username: "alice@example.com",
        smtpHost: "127.0.0.1",
        smtpPort: UInt16(port),
        smtpSecurity: Account.Security.none
    )
}

func makeIMAPAccount(port: Int) -> Account {
    Account(
        id: Account.ID("smoke-imap-\(UUID().uuidString)"),
        email: "alice@example.com",
        displayName: "Alice",
        kind: .imap,
        host: "127.0.0.1",
        port: UInt16(port),
        security: Account.Security.none,
        username: "alice@example.com"
    )
}

// MARK: - Сценарии

func runHappyPathSMTP(group: MultiThreadedEventLoopGroup) async throws {
    say("▶ SMTP happy-path: LiveSendProvider → fake-smtp")
    let server = try await FakeSMTPServer.start(on: group, behavior: .acceptAll)
    let port = server.port
    say("  fake-smtp listens on 127.0.0.1:\(port)")

    let account = makeSMTPAccount(port: port)
    let secrets = InMemorySecretsStore()
    try await secrets.setSMTPPassword("smoke-pwd", forAccount: account.id)

    let endpoint = SMTPEndpoint(host: "127.0.0.1", port: port, security: .plain)
    let provider = try LiveSendProvider(account: account, secrets: secrets, endpoint: endpoint)

    let envelope = Envelope(
        from: "alice@example.com",
        to: ["bob@example.com"],
        cc: ["carol@example.com"],
        bcc: ["secret@example.com"]
    )
    let composed = MIMEComposer.compose(
        from: "Alice <alice@example.com>",
        recipients: MIMEComposer.Recipients(
            to: ["bob@example.com"],
            cc: ["carol@example.com"],
            bcc: ["secret@example.com"]
        ),
        subject: "Привет, мир",
        body: "Тестовое письмо от smoke-сценария."
    )
    let body = MIMEBody(raw: composed)

    say("  send envelope → provider…")
    try await provider.send(envelope: envelope, body: body)
    say("  send returned")

    // Дать серверной актор-задаче время записать capture.
    try await Task.sleep(nanoseconds: 100_000_000)
    let store = server.captureStore
    guard let capture = await store.last else {
        die("FakeSMTPServer не получил DATA-блок")
    }

    check("EHLO получен сервером", capture.ehloSeen)
    check("AUTH PLAIN получен сервером", capture.authPlainSeen)
    check("MAIL FROM = alice@example.com", capture.mailFrom == "alice@example.com")
    check(
        "RCPT TO = to+cc+bcc (3 адреса)",
        capture.rcptTo == ["bob@example.com", "carol@example.com", "secret@example.com"]
    )

    let raw = capture.dataBlock
    check("DATA содержит From-заголовок", raw.contains("From: Alice <alice@example.com>"))
    check("DATA содержит To: bob", raw.contains("To: bob@example.com"))
    check("DATA содержит Cc: carol", raw.contains("Cc: carol@example.com"))
    check("DATA НЕ содержит Bcc-заголовка", !raw.contains("Bcc:"))
    check("Content-Type: text/plain; charset=utf-8",
          raw.contains("Content-Type: text/plain; charset=utf-8"))
    check("Content-Transfer-Encoding: quoted-printable",
          raw.contains("Content-Transfer-Encoding: quoted-printable"))
    check("Subject закодирован RFC 2047 (=?utf-8?B?...)",
          raw.contains("Subject: =?utf-8?B?"))
    check("Тело QP-кодировано (присутствует =XX-кириллицы)",
          raw.contains("=D0") || raw.contains("=D1"))
    check("Headers/body разделены CRLF CRLF", raw.contains("\r\n\r\n"))

    try await server.stop()
    say("✅ SMTP happy-path OK")
}

func runFailurePathSMTP(group: MultiThreadedEventLoopGroup) async throws {
    say("▶ SMTP failure-path: 550 на RCPT TO → провайдер бросает")
    let server = try await FakeSMTPServer.start(
        on: group,
        behavior: .rejectRecipient(reason: "User unknown in virtual mailbox table")
    )
    let port = server.port
    say("  fake-smtp listens on 127.0.0.1:\(port)")

    let account = makeSMTPAccount(port: port)
    let secrets = InMemorySecretsStore()
    try await secrets.setSMTPPassword("smoke-pwd", forAccount: account.id)

    let endpoint = SMTPEndpoint(host: "127.0.0.1", port: port, security: .plain)
    let provider = try LiveSendProvider(account: account, secrets: secrets, endpoint: endpoint)

    let envelope = Envelope(from: "alice@example.com", to: ["nobody@invalid.example"])
    let body = MIMEBody(raw: MIMEComposer.compose(
        from: "alice@example.com",
        recipients: MIMEComposer.Recipients(to: ["nobody@invalid.example"]),
        subject: "ping",
        body: "test"
    ))

    var didThrow = false
    var thrownDescription = ""
    do {
        try await provider.send(envelope: envelope, body: body)
    } catch let smtp as SMTPError {
        didThrow = true
        thrownDescription = "SMTPError: \(smtp)"
        if case .relay(let code, _) = smtp {
            check("SMTPError.relay с кодом 550", code == 550)
        } else {
            die("ожидался SMTPError.relay, получили \(smtp)")
        }
    } catch let mail as MailError {
        didThrow = true
        thrownDescription = "MailError: \(mail)"
    } catch {
        didThrow = true
        thrownDescription = "other error: \(error)"
    }
    check("send бросил ошибку при отказе сервера (\(thrownDescription))", didThrow)
    try await server.stop()
    say("✅ SMTP failure-path OK")
}

func runHappyPathIMAPDraft(group: MultiThreadedEventLoopGroup) async throws {
    say("▶ IMAP APPEND happy-path: LiveAccountDataProvider.saveDraft → fake-imap")
    let server = try await FakeIMAPServer.start(on: group)
    let port = server.port
    say("  fake-imap listens on 127.0.0.1:\(port)")

    let account = makeIMAPAccount(port: port)
    let secrets = InMemorySecretsStore()
    try await secrets.setPassword("smoke-pwd", forAccount: account.id)

    let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, security: .plain)
    let provider = LiveAccountDataProvider(
        account: account,
        secrets: secrets,
        endpoint: endpoint
    )

    let draftEnvelope = DraftEnvelope(
        from: "alice@example.com",
        to: ["bob@example.com"],
        subject: "Черновик smoke"
    )
    let body = "Содержимое черновика для smoke-теста."
    say("  saveDraft → provider…")
    try await provider.saveDraft(envelope: draftEnvelope, body: body)
    say("  saveDraft returned")

    try await Task.sleep(nanoseconds: 100_000_000)
    let store = server.captureStore
    let loginSeen = await store.loginSeen
    let listSeen = await store.listSeen
    check("LOGIN получен fake-imap", loginSeen)
    check("LIST получен fake-imap", listSeen)
    guard let capture = await store.lastAppend else {
        die("FakeIMAPServer не получил APPEND-литерал")
    }
    check("APPEND mailbox = Drafts", capture.mailbox == "Drafts")
    check("APPEND flags содержат \\Draft", capture.flags.contains(#"\Draft"#))
    let lit = capture.literal
    check("Литерал содержит From: alice@example.com",
          lit.contains("From: alice@example.com"))
    check("Литерал содержит To: bob@example.com",
          lit.contains("To: bob@example.com"))
    check("Литерал содержит закодированный Subject (RFC 2047)",
          lit.contains("Subject: =?utf-8?B?"))
    check("Литерал содержит Content-Type: text/plain",
          lit.contains("Content-Type: text/plain; charset=utf-8"))
    check("Литерал содержит Content-Transfer-Encoding: quoted-printable",
          lit.contains("Content-Transfer-Encoding: quoted-printable"))
    try await server.stop()
    say("✅ IMAP APPEND happy-path OK")
}

// MARK: - Entry point

@main
enum SMTPEndToEndSmokeMain {
    static func main() async throws {
        say("🧪 SMTPEndToEndSmoke")
        say(String(repeating: "=", count: 40))

        let group = MultiThreadedEventLoopGroup.singleton

        try await runHappyPathSMTP(group: group)
        try await runFailurePathSMTP(group: group)
        try await runHappyPathIMAPDraft(group: group)

        say(String(repeating: "=", count: 40))
        say("✅ SMTPEndToEndSmoke: все сценарии пройдены")
    }
}
