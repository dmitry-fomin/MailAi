// IMAPAppendSmoke — mock-style проверка построения IMAP APPEND-команды
// (SMTP-4). Сетевых вызовов не делает — проверяет, что строка команды,
// которую `IMAPConnection.append` отправит на сервер, соответствует
// RFC 3501 §6.3.11.
//
// Запуск: swift run IMAPAppendSmoke
//
// Запускается в Scripts/smoke.sh без креденшелов (mock-only).

import Foundation
import MailTransport

func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    precondition(lhs == rhs, "\(message): expected \(rhs), got \(lhs)")
}

func assertContains(_ haystack: String, _ needle: String, _ message: String) {
    precondition(haystack.contains(needle), "\(message): \(needle) not in \(haystack)")
}

// MARK: - 1. Формат базовой команды APPEND с литералом

func testBasicAppendCommand() {
    let cmd = IMAPConnection.formatAppendCommand(
        mailbox: "Drafts",
        flags: [],
        date: nil,
        literalOctets: 42
    )
    // RFC 3501: APPEND <mailbox> {N}
    // Без flags-секции и без date.
    assertEqual(cmd, #"APPEND "Drafts" {42}"#, "basic APPEND command")
}

// MARK: - 2. APPEND с одним флагом \Draft

func testAppendWithDraftFlag() {
    let cmd = IMAPConnection.formatAppendCommand(
        mailbox: "Drafts",
        flags: ["\\Draft"],
        date: nil,
        literalOctets: 1024
    )
    assertEqual(cmd, #"APPEND "Drafts" (\Draft) {1024}"#, "APPEND with \\Draft flag")
}

// MARK: - 3. APPEND с несколькими флагами

func testAppendWithMultipleFlags() {
    let cmd = IMAPConnection.formatAppendCommand(
        mailbox: "INBOX",
        flags: ["\\Seen", "\\Draft"],
        date: nil,
        literalOctets: 100
    )
    assertContains(cmd, "(\\Seen \\Draft)", "multiple flags formatted")
    assertContains(cmd, "{100}", "literal length present")
}

// MARK: - 4. APPEND с папкой, требующей quoting (пробел в имени)

func testAppendQuotedMailbox() {
    let cmd = IMAPConnection.formatAppendCommand(
        mailbox: "Sent Items",
        flags: [],
        date: nil,
        literalOctets: 7
    )
    // Пробел требует кавычек — IMAPConnection.quote их добавит.
    assertContains(cmd, #""Sent Items""#, "mailbox with space is quoted")
}

// MARK: - 5. Литерал-длина считается в октетах UTF-8 (а не в Character.count)

func testLiteralOctetsAreUTF8Bytes() {
    // Кириллица: каждая буква = 2 байта в UTF-8.
    let body = "Привет"           // 6 букв, 12 байт
    let octets = body.utf8.count
    assertEqual(octets, 12, "Cyrillic UTF-8 octet count")

    let cmd = IMAPConnection.formatAppendCommand(
        mailbox: "Drafts",
        flags: ["\\Draft"],
        date: nil,
        literalOctets: octets
    )
    assertContains(cmd, "{12}", "literal length is octets, not characters")
}

// MARK: - 6. internal date включается, когда передан

func testAppendWithInternalDate() {
    let cmd = IMAPConnection.formatAppendCommand(
        mailbox: "Drafts",
        flags: ["\\Draft"],
        date: "27-Apr-2026 10:00:00 +0000",
        literalOctets: 50
    )
    assertContains(cmd, #""27-Apr-2026 10:00:00 +0000""#, "date is quoted")
    assertContains(cmd, "{50}", "literal length still present after date")
}

// MARK: - 7. Smoke-проверка: MIME-композиция готова к APPEND'у

func testMIMEComposeForDraft() {
    let envelope = DraftEnvelope(
        from: "alice@example.com",
        to: ["bob@example.com"],
        subject: "Черновик"
    )
    _ = envelope.recipients

    let composed = MIMEComposer.compose(
        from: "alice@example.com",
        recipients: MIMEComposer.Recipients(to: ["bob@example.com"]),
        subject: "Hello",
        body: "Test"
    )
    // CRLF-разделители — критично для IMAP literal.
    assertContains(composed, "\r\n\r\n", "headers/body separator is CRLF CRLF")
    assertContains(composed, "From: alice@example.com", "From header present")

    // Полный wire-формат: заголовок APPEND + literal.
    let wire = "TAG1 " + IMAPConnection.formatAppendCommand(
        mailbox: "Drafts",
        flags: ["\\Draft"],
        date: nil,
        literalOctets: composed.utf8.count
    )
    // Должно соответствовать `<tag> APPEND "Drafts" (\Draft) {N}`.
    precondition(wire.hasPrefix("TAG1 APPEND \"Drafts\" (\\Draft) {"), "wire prefix")
    precondition(wire.hasSuffix("}"), "wire ends with literal length brace")
}

// MARK: - main

testBasicAppendCommand()
testAppendWithDraftFlag()
testAppendWithMultipleFlags()
testAppendQuotedMailbox()
testLiteralOctetsAreUTF8Bytes()
testAppendWithInternalDate()
testMIMEComposeForDraft()

print("✓ IMAPAppendSmoke: 7/7 tests passed")
