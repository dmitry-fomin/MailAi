import Foundation
import MailTransport

// IMAPSessionSmoke — ручная локальная проверка IMAPSession actor.
// Требует реальные креды из env: IMAP_HOST, IMAP_PORT (опц., 993), IMAP_USER,
// IMAP_PASSWORD. Дополнительные переменные: IMAP_TLS (опц., "1"/"0").
//
// Сценарий:
//   1) Создаём IMAPSession, вызываем start() (connect + LOGIN)
//   2) mailboxes() — LIST
//   3) select("INBOX")
//   4) uidFetchHeaders — до 5 последних заголовков
//   5) stop()
//
// Smoke-проверка: preconditions внутри. В git не коммитятся креды,
// CI бинарник не запускает.

func env(_ name: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
    return v
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

@main
struct IMAPSessionSmokeRunner {
    static func main() async throws {
        guard let host = env("IMAP_HOST") else {
            die("IMAP_HOST не задан. Пример: IMAP_HOST=imap.yandex.com IMAP_USER=... IMAP_PASSWORD=... swift run IMAPSessionSmoke")
        }
        guard let user = env("IMAP_USER") else { die("IMAP_USER не задан") }
        guard let password = env("IMAP_PASSWORD") else { die("IMAP_PASSWORD не задан") }
        let port = env("IMAP_PORT").flatMap(Int.init) ?? 993
        let useTLS = (env("IMAP_TLS") ?? "1") != "0"

        let endpoint = IMAPEndpoint(
            host: host,
            port: port,
            security: useTLS ? .tls : .plain
        )

        // 1. Создаём сессию — начальное состояние idle.
        let session = IMAPSession(
            endpoint: endpoint,
            username: user,
            password: password
        )
        let idleState = await session.state
        precondition(idleState == .idle, "Начальное состояние должно быть .idle, получили \(idleState)")

        log("▶ starting session → \(host):\(port) tls=\(useTLS)")

        // 2. start() — connect + LOGIN.
        try await session.start()
        let readyState = await session.state
        precondition(readyState == .ready, "После start() состояние должно быть .ready, получили \(readyState)")
        log("✓ session started, state = ready")

        // 3. mailboxes() — IMAP LIST.
        let mailboxes = try await session.mailboxes()
        precondition(!mailboxes.isEmpty, "Ожидали хотя бы один mailbox")
        log("✓ LIST: \(mailboxes.count) mailboxes")
        for mb in mailboxes {
            log("    [\(mb.flags.joined(separator: ","))] \(mb.delimiter ?? "NIL") \(mb.path)")
        }

        // 4. select("INBOX").
        let selectResult = try await session.select("INBOX")
        precondition(selectResult.exists >= 0, "exists должен быть >= 0")
        log("✓ SELECT INBOX: exists=\(selectResult.exists) uidNext=\(selectResult.uidNext ?? 0)")

        // 5. uidFetchHeaders — до 5 последних.
        if let uidNext = selectResult.uidNext, uidNext > 1 {
            let upper = uidNext - 1
            let lower = upper >= 5 ? upper - 4 : 1
            let range = IMAPUIDRange(lower: lower, upper: upper)

            let (fetches, parseErrors) = try await session.uidFetchHeaders(range: range)
            log("✓ FETCH \(range.command): \(fetches.count) писем, parseErrors=\(parseErrors)")
            for f in fetches {
                let subj = f.envelope?.subject ?? "<no-subject>"
                log("    UID=\(f.uid ?? 0) subj=\(subj)")
            }
        } else {
            log("⚠ INBOX пуст — пропускаем FETCH")
        }

        // 6. stop() — graceful shutdown.
        await session.stop()
        let finalState = await session.state
        if case .disconnected = finalState {
            log("✓ session stopped, state = disconnected")
        } else {
            log("⚠ неожиданное состояние после stop: \(finalState)")
        }

        log("✅ IMAPSessionSmoke passed")
    }
}
