import Foundation
import Core
import AppShell
import MailTransport

/// AI-7: smoke-проверки серверной синхронизации Important/Unimportant.
///
/// Без живой сети: проверяем форматирование IMAP-команд (CREATE / UID MOVE),
/// поведение per-account toggle и обработку ошибки «уже существует».
@main
enum ServerSyncSmoke {
    static func main() async throws {
        func check(_ label: String, _ condition: Bool) {
            guard condition else {
                FileHandle.standardError.write(Data("✘ \(label)\n".utf8))
                exit(1)
            }
            print("✓ \(label)")
        }

        // ── Test 1: имя CREATE-команды и пути папок ───────────────────────
        do {
            let importantPathSlash = IMAPServerFolderSync.path(for: .important, delimiter: "/")
            let unimportantPathSlash = IMAPServerFolderSync.path(for: .unimportant, delimiter: "/")
            check("Path: MailAi/Important",   importantPathSlash == "MailAi/Important")
            check("Path: MailAi/Unimportant", unimportantPathSlash == "MailAi/Unimportant")

            // Dovecot может отдавать `.` как делимитер.
            let importantPathDot = IMAPServerFolderSync.path(for: .important, delimiter: ".")
            check("Path with dot delimiter:    MailAi.Important",   importantPathDot == "MailAi.Important")

            // Fallback на `/`, если делимитер пустой/nil.
            let fallback = IMAPServerFolderSync.path(for: .important, delimiter: nil)
            check("Path fallback `/` для nil delimiter", fallback == "MailAi/Important")
            let fallbackEmpty = IMAPServerFolderSync.path(for: .important, delimiter: "")
            check("Path fallback `/` для пустого delimiter", fallbackEmpty == "MailAi/Important")
        }

        // ── Test 2: команда CREATE — корректный синтаксис RFC 3501 ────────
        do {
            let cmd = IMAPServerFolderSync.createCommand(for: .important, delimiter: "/")
            check("CREATE формат RFC 3501",
                  cmd == "CREATE \"MailAi/Important\"")

            let cmdU = IMAPServerFolderSync.createCommand(for: .unimportant, delimiter: ".")
            check("CREATE с делимитером `.`",
                  cmdU == "CREATE \"MailAi.Unimportant\"")
        }

        // ── Test 3: UID MOVE — корректный синтаксис RFC 6851 ──────────────
        do {
            let cmd = IMAPServerFolderSync.uidMoveCommand(uid: 42, target: .important, delimiter: "/")
            check("UID MOVE формат RFC 6851",
                  cmd == "UID MOVE 42 \"MailAi/Important\"")

            let cmdU = IMAPServerFolderSync.uidMoveCommand(uid: 1001, target: .unimportant, delimiter: "/")
            check("UID MOVE для unimportant с UID 1001",
                  cmdU == "UID MOVE 1001 \"MailAi/Unimportant\"")
        }

        // ── Test 4: per-account toggle через AISettingsStore ──────────────
        do {
            let suiteA = "ai7.smoke.\(UUID().uuidString)"
            let store = makeIsolatedStore(suiteName: suiteA)
            let accA = Account.ID("acc-a")
            let accB = Account.ID("acc-b")

            let initialA = await store.serverSyncEnabled(forAccount: accA)
            check("Toggle: по умолчанию выключен", initialA == false)

            await store.setServerSyncEnabled(true, forAccount: accA)
            let afterA = await store.serverSyncEnabled(forAccount: accA)
            check("Toggle: включается per-account A", afterA == true)

            let stillOffB = await store.serverSyncEnabled(forAccount: accB)
            check("Toggle: per-account изоляция (B остаётся false)", stillOffB == false)

            await store.setServerSyncEnabled(false, forAccount: accA)
            let backOff = await store.serverSyncEnabled(forAccount: accA)
            check("Toggle: выключается обратно", backOff == false)
        }

        // ── Test 5: гейт по toggle — при выключенном hook не должен звать
        //              никаких сетевых операций. Эмулируем через счётчик
        //              вызовов hook-обёртки, которая стреляет только когда
        //              toggle включён.
        do {
            let suite = "ai7.gate.\(UUID().uuidString)"
            let store = makeIsolatedStore(suiteName: suite)
            let accID = Account.ID("acc-gate")

            // Toggle выключен — hook не должен дёрнуть «сетевую» функцию.
            let counter = MoveCounter()
            await maybeMove(toggleStore: store, accountID: accID, counter: counter, target: .important)
            let afterOff = await counter.value
            check("Гейт: выключенный toggle не вызывает MOVE", afterOff == 0)

            // Включаем toggle — hook сработает.
            await store.setServerSyncEnabled(true, forAccount: accID)
            await maybeMove(toggleStore: store, accountID: accID, counter: counter, target: .unimportant)
            let afterOn = await counter.value
            check("Гейт: включенный toggle вызывает MOVE один раз", afterOn == 1)

            // suiteName уникальный — оставляем без cleanup, чтобы не делить
            // ссылку на defaults между actor-изолированным store и main.
        }

        // ── Test 6: обработка ошибки «уже существует» ─────────────────────
        do {
            let err1 = IMAPConnection.CreateMailboxError.alreadyExists(text: "[ALREADYEXISTS] Mailbox exists")
            switch err1 {
            case .alreadyExists:
                check("CreateMailboxError.alreadyExists различим", true)
            case .failed:
                check("CreateMailboxError.alreadyExists различим", false)
            }

            // Параметры цели — все имена покрыты CaseIterable.
            check("Target.allCases == [.important, .unimportant]",
                  IMAPServerFolderSync.Target.allCases == [.important, .unimportant])
        }

        print("✅ ServerSyncSmoke OK")
    }
}

/// Создаёт изолированный AISettingsStore с per-test UserDefaults, не возвращая
/// ссылку на сам defaults — она остаётся внутри функции и достанется только
/// actor'у. Это удовлетворяет проверки strict concurrency.
func makeIsolatedStore(suiteName: String) -> AISettingsStore {
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    return AISettingsStore(defaults: defaults)
}

/// Простой actor-счётчик «сколько раз дёрнули MOVE».
actor MoveCounter {
    var value: Int = 0
    func bump() { value += 1 }
}

/// Эмуляция вызова из координатора: проверяем гейт по toggle и при
/// включённом флаге увеличиваем счётчик. Сетевого I/O нет.
func maybeMove(
    toggleStore: AISettingsStore,
    accountID: Account.ID,
    counter: MoveCounter,
    target: IMAPServerFolderSync.Target
) async {
    let enabled = await toggleStore.serverSyncEnabled(forAccount: accountID)
    guard enabled else { return }
    _ = target
    await counter.bump()
}
