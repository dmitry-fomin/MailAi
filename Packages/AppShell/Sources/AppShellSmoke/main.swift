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

        // A7: AccountRegistry — дедупликация сессий и release.
        let registry = await AccountRegistry(accounts: [provider.account], mode: .mock)
        let s1 = await registry.session(for: provider.account.id)
        let s2 = await registry.session(for: provider.account.id)
        check("AccountRegistry переиспользует сессию для одного Account.ID",
              s1 != nil && s1 === s2)

        await registry.releaseSession(for: provider.account.id)
        let s3 = await registry.session(for: provider.account.id)
        check("После releaseSession реестр выдаёт новую сессию",
              s3 != nil && s3 !== s1)

        let missing = await registry.session(for: .init("unknown"))
        check("Неизвестный Account.ID → nil", missing == nil)

        // C3: AppShellConfig.fromEnvironment — MOCK_DATA управляет режимом.
        check("MOCK_DATA=1 → .mock",
              AppShellConfig.fromEnvironment(["MOCK_DATA": "1"]).mode == .mock)
        check("MOCK_DATA отсутствует → .live",
              AppShellConfig.fromEnvironment([:]).mode == .live)
        check("MOCK_DATA=0 → .live",
              AppShellConfig.fromEnvironment(["MOCK_DATA": "0"]).mode == .live)

        // Фабрика возвращает live-провайдер для .live — сам LiveAccountDataProvider
        // ещё throws (фаза B), но тип должен быть правильным.
        let liveProvider = AccountDataProviderFactory.make(for: provider.account, mode: .live)
        check("Factory для .live возвращает LiveAccountDataProvider",
              String(describing: type(of: liveProvider)).contains("LiveAccountDataProvider"))

        print("\nAll AppShell smoke checks passed.")
    }
}
