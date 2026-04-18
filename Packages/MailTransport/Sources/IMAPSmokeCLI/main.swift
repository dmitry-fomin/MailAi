import Foundation
import Core
import MailTransport

// IMAPSmokeCLI — ручная локальная smoke-проверка IMAP-транспорта.
// Требует реальные креды из env: IMAP_HOST, IMAP_PORT (опц., 993), IMAP_USER,
// IMAP_PASSWORD, IMAP_MAILBOX (опц., INBOX), IMAP_TLS (опц., "1"/"0").
//
// Сценарий:
//   1) Connect + greeting + CAPABILITY + LOGIN
//   2) LIST "" "*" — печать всех папок
//   3) SELECT <mailbox>
//   4) UID FETCH до 10 заголовков (последние UID: от max(uidNext-10,1) до uidNext-1)
//   5) Стрим тела первого (самого нового) UID в stdout, затем LOGOUT
//
// В git не коммитятся креды, CI этот бинарник не запускает.

func env(_ name: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
    return v
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

@main
enum IMAPSmokeCLIRunner {
    static func main() async throws {
        try await runSmoke()
    }
}

func runSmoke() async throws {
        guard let host = env("IMAP_HOST") else {
            die("IMAP_HOST не задан. Пример: IMAP_HOST=imap.yandex.com IMAP_USER=... IMAP_PASSWORD=... swift run IMAPSmokeCLI")
        }
        guard let user = env("IMAP_USER") else { die("IMAP_USER не задан") }
        guard let password = env("IMAP_PASSWORD") else { die("IMAP_PASSWORD не задан") }
        let port = env("IMAP_PORT").flatMap(Int.init) ?? 993
        let mailbox = env("IMAP_MAILBOX") ?? "INBOX"
        let useTLS = (env("IMAP_TLS") ?? "1") != "0"

        let endpoint = IMAPEndpoint(
            host: host,
            port: port,
            security: useTLS ? .tls : .plain
        )

        FileHandle.standardError.write(Data("▶ connecting \(host):\(port) tls=\(useTLS)\n".utf8))

        try await IMAPConnection.withOpen(endpoint: endpoint) { conn in
            FileHandle.standardError.write(Data("✓ greeting: \(conn.greeting.raw)\n".utf8))

            let caps = try await conn.capability()
            FileHandle.standardError.write(Data("✓ CAPABILITY: \(caps.joined(separator: " "))\n".utf8))

            try await conn.login(username: user, password: password)
            FileHandle.standardError.write(Data("✓ LOGIN ok\n".utf8))

            let folders = try await conn.list()
            FileHandle.standardError.write(Data("✓ LIST (\(folders.count)):\n".utf8))
            for entry in folders {
                let delim = entry.delimiter ?? "NIL"
                FileHandle.standardError.write(
                    Data("    [\(entry.flags.joined(separator: ","))] \(delim) \(entry.path)\n".utf8)
                )
            }

            let sel = try await conn.select(mailbox)
            FileHandle.standardError.write(Data(
                "✓ SELECT \(mailbox): exists=\(sel.exists) uidNext=\(sel.uidNext ?? 0) uidValidity=\(sel.uidValidity ?? 0)\n".utf8
            ))

            guard let uidNext = sel.uidNext, uidNext > 1 else {
                FileHandle.standardError.write(Data("⚠ папка пуста или нет UIDNEXT — завершаем\n".utf8))
                try await conn.logout()
                return
            }

            let upper = uidNext - 1
            let lower = upper >= 10 ? upper - 9 : 1
            let range = IMAPUIDRange(lower: lower, upper: upper)

            let (fetches, parseErrors) = try await conn.uidFetchHeaders(range: range)
            FileHandle.standardError.write(Data(
                "✓ FETCH headers \(range.command): \(fetches.count) писем, parseErrors=\(parseErrors)\n".utf8
            ))
            for f in fetches.prefix(10) {
                let subj = f.envelope?.subject ?? "<no-subject>"
                let from: String = f.envelope?.from.first.map { addr in
                    let mb = addr.mailbox ?? "?"
                    let host = addr.host ?? "?"
                    return "\(mb)@\(host)"
                } ?? "<no-from>"
                FileHandle.standardError.write(Data(
                    "    UID=\(f.uid ?? 0) size=\(f.rfc822Size ?? 0) from=\(from) subj=\(subj)\n".utf8
                ))
            }

            guard let newest = fetches.compactMap({ $0.uid }).max() else {
                FileHandle.standardError.write(Data("⚠ не удалось выбрать UID для стрима тела\n".utf8))
                try await conn.logout()
                return
            }

            FileHandle.standardError.write(Data("▶ streaming body UID=\(newest) -> stdout\n".utf8))
            var totalBytes = 0
            for try await chunk in conn.streamBody(uid: newest) {
                totalBytes += chunk.bytes.count
                try FileHandle.standardOutput.write(contentsOf: chunk.bytes)
            }
            FileHandle.standardError.write(Data("✓ streamed \(totalBytes) bytes\n".utf8))

            try await conn.logout()
            FileHandle.standardError.write(Data("✓ LOGOUT\n".utf8))
        }

    FileHandle.standardError.write(Data("✅ IMAPSmokeCLI done\n".utf8))
}
