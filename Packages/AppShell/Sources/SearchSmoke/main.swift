import Foundation
import Core
import Storage

// Search-3: smoke-проверка FTS-поиска.
// Сценарий: GRDB на диске, пишем набор сообщений, запускаем разные запросы
// через GRDBSearchService + SearchQueryParser.

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(msg)\n".utf8))
    exit(1)
}

func check(_ label: String, _ cond: Bool) {
    guard cond else { die(label) }
    print("✓ \(label)")
}

@main
enum SearchSmokeRunner {
    static func main() async throws { try await runSearch() }
}

func runSearch() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailai-search-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = try GRDBMetadataStore(url: tmp.appendingPathComponent("metadata.sqlite"))

    let account = Account(
        id: Account.ID("search-account"),
        email: "me@example.com",
        displayName: nil,
        kind: .imap,
        host: "imap.example.com",
        port: 993,
        security: .tls,
        username: "me"
    )
    try await store.upsert(account)
    let inbox = Mailbox(
        id: Mailbox.ID("INBOX"),
        accountID: account.id,
        name: "INBOX", path: "INBOX", role: .inbox,
        unreadCount: 0, totalCount: 0, uidValidity: 1
    )
    try await store.upsert(inbox)

    // Набор сообщений.
    func make(_ uid: UInt32, subject: String, from: MailAddress, flags: MessageFlags, date: Date) -> Message {
        Message(
            id: Message.ID("msg-\(uid)"),
            accountID: account.id, mailboxID: inbox.id, uid: uid,
            messageID: "<\(uid)@example.com>", threadID: nil,
            subject: subject, from: from, to: [], cc: [],
            date: date, preview: nil, size: 1024,
            flags: flags, importance: .unknown
        )
    }
    let alice = MailAddress(address: "alice@example.com", name: "Alice")
    let bob = MailAddress(address: "bob@example.com", name: "Bob")
    let d2026 = DateComponents(calendar: .init(identifier: .gregorian),
                               timeZone: .init(identifier: "UTC"),
                               year: 2026, month: 4, day: 10).date!
    let d2025 = DateComponents(calendar: .init(identifier: .gregorian),
                               timeZone: .init(identifier: "UTC"),
                               year: 2025, month: 12, day: 1).date!
    let messages: [Message] = [
        make(1, subject: "Invoice for April", from: alice, flags: [], date: d2026),
        make(2, subject: "Lunch next week?", from: bob, flags: [.seen], date: d2026),
        make(3, subject: "Quarterly report", from: alice, flags: [.seen, .hasAttachment], date: d2025),
        make(4, subject: "Vacation photos", from: bob, flags: [.flagged, .hasAttachment], date: d2025)
    ]
    try await store.upsert(messages)

    let search = GRDBSearchService(pool: store.pool)

    // 1) Свободный текст
    let invoiceHits = try await search.search(rawQuery: "invoice", accountID: account.id, mailboxID: nil, limit: 50)
    check("«invoice» → 1 результат", invoiceHits.count == 1)
    check("первый hit — Invoice for April", invoiceHits.first?.subject.contains("Invoice") == true)

    // 2) from:
    let aliceHits = try await search.search(rawQuery: "from:alice", accountID: account.id, mailboxID: nil, limit: 50)
    check("«from:alice» → 2 письма от Alice", aliceHits.count == 2)

    // 3) is:unread — уид 1 (no flags) + уид 4 (flagged|hasAttachment, нет seen)
    let unreadHits = try await search.search(rawQuery: "is:unread", accountID: account.id, mailboxID: nil, limit: 50)
    check("«is:unread» → 2 непрочитанных", unreadHits.count == 2)

    // 4) has:attachment
    let attachHits = try await search.search(rawQuery: "has:attachment", accountID: account.id, mailboxID: nil, limit: 50)
    check("«has:attachment» → 2 письма", attachHits.count == 2)

    // 5) Комбо: from:alice has:attachment
    let combo = try await search.search(rawQuery: "from:alice has:attachment", accountID: account.id, mailboxID: nil, limit: 50)
    check("«from:alice has:attachment» → 1 (Quarterly report)", combo.count == 1)
    check("combo hit — Quarterly report", combo.first?.subject == "Quarterly report")

    // 6) before:
    let oldHits = try await search.search(rawQuery: "before:2026-01-01", accountID: account.id, mailboxID: nil, limit: 50)
    check("«before:2026-01-01» → 2 письма из 2025", oldHits.count == 2)

    // 7) is:flagged
    let flaggedHits = try await search.search(rawQuery: "is:flagged", accountID: account.id, mailboxID: nil, limit: 50)
    check("«is:flagged» → 1 (Vacation photos)", flaggedHits.count == 1)

    // 8) Пустой запрос
    let empty = try await search.search(rawQuery: "   ", accountID: account.id, mailboxID: nil, limit: 50)
    check("пустой запрос → []", empty.isEmpty)

    print("✅ SearchSmoke OK")
}
