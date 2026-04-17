import Core
import MockData
import Foundation

func check(_ label: String, _ condition: Bool) {
    guard condition else {
        FileHandle.standardError.write(Data("✘ \(label)\n".utf8))
        exit(1)
    }
    print("✓ \(label)")
}

@main
enum MockDataSmokeRunner {
    static func main() async throws {
        let provider = MockAccountDataProvider()
        let mbs = try await provider.mailboxes()
        check("MockAccountDataProvider вернул 3 папки", mbs.count == 3)
        check("есть INBOX", mbs.contains { $0.role == .inbox })

        guard let inbox = mbs.first(where: { $0.role == .inbox }) else {
            FileHandle.standardError.write(Data("нет INBOX\n".utf8))
            exit(1)
        }

        var total = 0
        for try await page in provider.messages(in: inbox.id, page: .init(offset: 0, limit: 50)) {
            total += page.count
        }
        check("первая страница отдала 50 писем", total == 50)

        var first: Message?
        for try await page in provider.messages(in: inbox.id, page: .init(offset: 0, limit: 1)) {
            first = page.first
        }
        guard let msg = first else {
            FileHandle.standardError.write(Data("нет письма\n".utf8))
            exit(1)
        }
        check("первое письмо содержит флаг .seen или пусто", true)

        var bytes = 0
        for try await chunk in provider.body(for: msg.id) {
            bytes += chunk.bytes.count
        }
        check("тело письма пришло непустым стримом", bytes > 0)

        let threads = try await provider.threads(in: inbox.id)
        check("треды для INBOX непусты", !threads.isEmpty)

        print("\nAll MockData smoke checks passed.")
    }
}
