import Core
import Foundation

// Smoke-tests для окружения без Xcode (CLT-only). Запускается через
// `swift run CoreSmoke` и падает с fatalError при провале инварианта.
// Дублирует критичные проверки из XCTest-таргета, чтобы разработка
// без Xcode сохраняла обратную связь по изменениям моделей.

func check(_ label: String, _ condition: Bool) {
    guard condition else {
        FileHandle.standardError.write(Data("✘ \(label)\n".utf8))
        exit(1)
    }
    print("✓ \(label)")
}

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
check("Account Codable round-trip", decoded == account)

let flags: MessageFlags = [.seen, .flagged, .hasAttachment]
check("MessageFlags содержит .seen", flags.contains(.seen))
check("MessageFlags не содержит .deleted", !flags.contains(.deleted))

let inbox = Mailbox(
    id: .init("mb-inbox"),
    accountID: account.id,
    name: "INBOX",
    path: "INBOX",
    role: .inbox,
    unreadCount: 5,
    totalCount: 100,
    uidValidity: 42
)
check("Mailbox.role == .inbox", inbox.role == .inbox)
check("Mailbox.children пуст по умолчанию", inbox.children.isEmpty)

let err = MailError.authentication(.invalidCredentials)
let desc = err.localizedDescription
check("MailError.localizedDescription не пуст", !desc.isEmpty)
check("MailError не утекает '@'", !desc.contains("@"))

check("Importance.unknown присутствует", Importance.allCases.contains(.unknown))

let thread = MessageThread(
    id: .init("t-1"),
    accountID: account.id,
    subject: "Re: hello",
    messageIDs: [.init("m-1"), .init("m-2")],
    lastDate: Date(timeIntervalSince1970: 1_700_000_000)
)
check("MessageThread хранит список messageIDs", thread.messageIDs.count == 2)

print("\nAll Core smoke checks passed.")
