import Foundation
import Core

/// In-memory провайдер для dev-режима (`--mock`). Отдаёт 200 писем в 3 папках,
/// 2 треда, фиктивные тела. Никакой сети и файлов.
///
/// Используется в Потоке A (UI-first на моках) — см. IMPLEMENTATION_PLAN.md.
public struct MockAccountDataProvider: AccountDataProvider {
    public let account: Account
    private let fixture: MockFixture

    public init(seed: UInt64 = 42) {
        let fixture = MockFixture.generate(seed: seed)
        self.account = fixture.account
        self.fixture = fixture
    }

    public func mailboxes() async throws -> [Mailbox] { fixture.mailboxes }

    public func messages(in mailbox: Mailbox.ID, page: Page) -> AsyncThrowingStream<[Message], any Error> {
        let all = fixture.messages.filter { $0.mailboxID == mailbox }
            .sorted { $0.date > $1.date }
        let start = min(page.offset, all.count)
        let end = min(start + page.limit, all.count)
        let slice = Array(all[start..<end])
        return AsyncThrowingStream { continuation in
            continuation.yield(slice)
            continuation.finish()
        }
    }

    public func body(for message: Message.ID) -> AsyncThrowingStream<ByteChunk, any Error> {
        let plain = fixture.bodies[message] ?? "(mock body missing)"
        let bytes = Array(plain.utf8)
        return AsyncThrowingStream { continuation in
            let chunkSize = 256
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunkSize, bytes.count)
                continuation.yield(ByteChunk(bytes: Array(bytes[offset..<end])))
                offset = end
            }
            continuation.finish()
        }
    }

    public func threads(in mailbox: Mailbox.ID) async throws -> [MessageThread] {
        fixture.threads.filter { thread in
            // тред привязан к mailbox, если хотя бы одно сообщение там
            thread.messageIDs.contains { id in
                fixture.messages.first(where: { $0.id == id })?.mailboxID == mailbox
            }
        }
    }
}

struct MockFixture: Sendable {
    let account: Account
    let mailboxes: [Mailbox]
    let messages: [Message]
    let threads: [MessageThread]
    let bodies: [Message.ID: String]

    static func generate(seed: UInt64) -> MockFixture {
        let accountID = Account.ID("mock-account")
        let account = Account(
            id: accountID,
            email: "mock@local",
            displayName: "Mock User",
            kind: .imap,
            host: "localhost",
            port: 0,
            security: .none,
            username: "mock"
        )

        let inbox = Mailbox(
            id: .init("mock-inbox"), accountID: accountID,
            name: "INBOX", path: "INBOX", role: .inbox,
            unreadCount: 0, totalCount: 150, uidValidity: 1
        )
        let sent = Mailbox(
            id: .init("mock-sent"), accountID: accountID,
            name: "Отправленные", path: "Sent", role: .sent,
            unreadCount: 0, totalCount: 30, uidValidity: 1
        )
        let archive = Mailbox(
            id: .init("mock-archive"), accountID: accountID,
            name: "Архив", path: "Archive", role: .archive,
            unreadCount: 0, totalCount: 20, uidValidity: 1
        )
        let mailboxes = [inbox, sent, archive]

        var rng = SplitMix64(state: seed)
        let subjects = [
            "Отчёт за неделю", "Встреча в четверг", "Re: планирование",
            "Fwd: документы", "Счёт на оплату", "Приглашение на конференцию",
            "Статус проекта", "Ваша подписка", "Code review", "Релиз 1.2"
        ]
        let senders = [
            MailAddress(address: "alice@example.com", name: "Алиса"),
            MailAddress(address: "bob@example.com", name: "Боб"),
            MailAddress(address: "ci@build.local", name: "CI"),
            MailAddress(address: "noreply@bank.example", name: "Банк")
        ]

        var messages: [Message] = []
        var bodies: [Message.ID: String] = [:]
        let baseDate = Date(timeIntervalSince1970: 1_735_000_000)

        let distribution: [(Mailbox, Int)] = [(inbox, 150), (sent, 30), (archive, 20)]
        var counter = 0
        for (mailbox, count) in distribution {
            for i in 0..<count {
                counter += 1
                let subject = subjects[Int(rng.next() % UInt64(subjects.count))]
                let from = senders[Int(rng.next() % UInt64(senders.count))]
                let msgID = Message.ID("mock-\(counter)")
                let unread = (mailbox.role == .inbox) && (i % 5 == 0)
                let hasAttach = (i % 7 == 0)
                var flags: MessageFlags = unread ? [] : [.seen]
                if hasAttach { flags.insert(.hasAttachment) }

                let msg = Message(
                    id: msgID,
                    accountID: accountID,
                    mailboxID: mailbox.id,
                    uid: UInt32(counter),
                    messageID: "<\(counter)@mock.local>",
                    threadID: nil,
                    subject: "\(subject) #\(i + 1)",
                    from: from,
                    to: [MailAddress(address: "mock@local", name: "Mock User")],
                    cc: [],
                    date: baseDate.addingTimeInterval(Double(-i) * 3600),
                    preview: "Краткое превью сообщения про «\(subject)». Нажмите, чтобы прочесть полностью.",
                    size: 2048 + i * 13,
                    flags: flags,
                    importance: .unknown
                )
                messages.append(msg)
                bodies[msgID] = "Это тестовое тело письма №\(counter).\nТема: \(msg.subject).\n\n" +
                    "Контент только в памяти, на диск не пишется. " +
                    "Строка \(i + 1) из \(count) в папке \(mailbox.name)."
            }
        }

        // Два треда — из первых писем inbox
        let inboxMessages = messages.filter { $0.mailboxID == inbox.id }.prefix(4)
        let firstThread = MessageThread(
            id: .init("thread-1"), accountID: accountID,
            subject: "Re: планирование",
            messageIDs: Array(inboxMessages.prefix(2).map(\.id)),
            lastDate: inboxMessages.first?.date ?? baseDate
        )
        let secondThread = MessageThread(
            id: .init("thread-2"), accountID: accountID,
            subject: "Отчёт за неделю",
            messageIDs: Array(inboxMessages.suffix(2).map(\.id)),
            lastDate: inboxMessages.last?.date ?? baseDate
        )

        return MockFixture(
            account: account,
            mailboxes: mailboxes,
            messages: messages,
            threads: [firstThread, secondThread],
            bodies: bodies
        )
    }
}

/// Детерминированный PRNG для воспроизводимых моков.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
