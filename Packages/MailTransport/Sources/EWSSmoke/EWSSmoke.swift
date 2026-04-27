import Foundation
import MailTransport
import Core

@main
struct EWSSmoke {
    static func main() async {
        do {
            try await run()
        } catch {
            print("FAILED: \(error)")
        }
    }

    static func run() async throws {
        let email = "fomin.dmitriy@zoloto585.ru"
        let password = "cortu7-buCqeh-jebzeb"

        print("=== EWS Smoke Test ===")
        print("Email: \(email)\n")

        // 1. Autodiscover
        print("1. Autodiscover...")
        let ewsURL = try await EWSClient.autodiscover(email: email, password: password)
        print("   EWS URL: \(ewsURL)\n")

        // 2. GetFolder
        let client = EWSClient(ewsURL: ewsURL, username: email, password: password)
        print("2. GetFolder (inbox, sent, drafts, deleted)...")
        let folders = try await client.getFolders(ids: [.inbox, .sentitems, .drafts, .deleteditems])
        for f in folders {
            print("   [\(f.displayName)] total=\(f.totalCount) unread=\(f.unreadCount)")
        }
        print()

        // 3. FindItem (первые 5 писем во входящих)
        guard let inbox = folders.first else {
            print("Inbox not found"); return
        }
        print("3. FindItem inbox (5 писем)...")
        let result = try await client.findItems(folderID: inbox.id, offset: 0, maxCount: 5)
        print("   Всего в inbox: \(result.totalCount)")
        for item in result.items {
            let fromStr = item.from.map { "\($0.name ?? "") <\($0.address)>" } ?? "(нет)"
            print("   • \(item.subject)")
            print("     От: \(fromStr), прочитано=\(item.isRead)")
        }
        print()
        print("=== OK ===")
    }
}
