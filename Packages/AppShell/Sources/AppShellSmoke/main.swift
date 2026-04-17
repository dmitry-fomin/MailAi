import Foundation
import Core
import MockData
import AppShell

func check(_ label: String, _ condition: Bool) {
    guard condition else {
        FileHandle.standardError.write(Data("✘ \(label)\n".utf8))
        exit(1)
    }
    print("✓ \(label)")
}

@main
enum AppShellSmokeRunner {
    static func main() async throws {
        let provider = MockAccountDataProvider()
        let session = await AccountSessionModel(account: provider.account, provider: provider)

        await session.loadMailboxes()
        let mailboxes = await session.mailboxes
        check("AccountSessionModel.loadMailboxes вернул 3 папки", mailboxes.count == 3)

        let selected = await session.selectedMailboxID
        check("selectedMailboxID автоматически указал на INBOX",
              selected == mailboxes.first(where: { $0.role == .inbox })?.id)

        // Даём messagesTask завершиться (стрим mock-а одноразовый).
        try await Task.sleep(nanoseconds: 200_000_000)

        let messages = await session.messages
        check("messages загружены (>0)", !messages.isEmpty)

        guard let firstMessage = messages.first else { exit(1) }
        await session.open(messageID: firstMessage.id)

        // Дать openBody собраться.
        try await Task.sleep(nanoseconds: 300_000_000)
        let body = await session.openBody
        check("openBody сформирован после open(messageID:)", body != nil)

        session.closeSession()
        let bodyAfterClose = session.openBody
        check("openBody == nil после closeSession (инвариант памяти)", bodyAfterClose == nil)

        let messagesAfterClose = session.messages
        check("messages очищены после closeSession", messagesAfterClose.isEmpty)

        print("\nAll AppShell smoke checks passed.")
    }
}
