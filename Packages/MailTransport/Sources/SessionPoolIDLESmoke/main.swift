import Foundation
import MailTransport
import NIOCore
import NIOPosix

// Pool-4 — smoke session pool + IDLE.
//
// Поднимает локальный fake IMAP-сервер, эмулирующий минимально
// LOGIN / SELECT / IDLE (с DONE) / UID FETCH / LOGOUT. Поверх него
// запускает IMAPSession (командный канал) + IMAPIdleController
// (отдельное соединение под IDLE).
//
// Проверяемые инварианты:
//   1) После SELECT + IDLE сервер шлёт "* N EXISTS" → IMAPIdleController
//      публикует .exists(mailbox:count:) в AsyncStream без ручного refresh.
//   2) В ответ на это потребитель делает UID FETCH через IMAPSession и
//      получает обновлённый список (diff по uidNext).
//   3) При stop() IMAPIdleController отправляет DONE (это видит сервер),
//      а IMAPSession отправляет LOGOUT либо его соединение закрывается.
//
// NO real network calls. Запуск: `swift run SessionPoolIDLESmoke`.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

func check(_ label: String, _ condition: Bool) {
    guard condition else { die(label) }
    FileHandle.standardError.write(Data("✓ \(label)\n".utf8))
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// Запускает асинхронную работу с таймаутом. Если таймаут истёк — падаем с
/// диагностической ошибкой (smoke-цель — выявлять зависания, а не игнорить их).
func withTimeout(
    seconds: Int,
    label: String,
    _ work: @escaping @Sendable () async -> Void
) async {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await work()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        if !first {
            die("\(label) повис более \(seconds)s")
        }
    }
}

// MARK: - Fake IMAP server

/// Потокобезопасный счётчик сигналов от сервера в smoke-тест.
final class ServerSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _idleStarted = false
    private var _doneSeen = false
    private var _logoutSeen = false
    private var _channelClosedNonGracefully = false
    private var _idleConnContinuations: [CheckedContinuation<Void, Never>] = []

    var idleStarted: Bool { lock.lock(); defer { lock.unlock() }; return _idleStarted }
    var doneSeen: Bool { lock.lock(); defer { lock.unlock() }; return _doneSeen }
    var logoutSeen: Bool { lock.lock(); defer { lock.unlock() }; return _logoutSeen }
    var channelClosedNonGracefully: Bool {
        lock.lock(); defer { lock.unlock() }; return _channelClosedNonGracefully
    }

    func markIdleStarted() {
        lock.lock()
        let waiters = _idleConnContinuations
        _idleConnContinuations.removeAll()
        _idleStarted = true
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func markDone() { lock.lock(); _doneSeen = true; lock.unlock() }
    func markLogout() { lock.lock(); _logoutSeen = true; lock.unlock() }
    func markChannelClosed() { lock.lock(); _channelClosedNonGracefully = true; lock.unlock() }

    /// Ждёт момент, когда хотя бы одно соединение войдёт в IDLE.
    func waitIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _idleStarted {
                lock.unlock()
                cont.resume()
            } else {
                _idleConnContinuations.append(cont)
                lock.unlock()
            }
        }
    }
}

/// Команда серверу из теста: «толкни EXISTS в активное IDLE-соединение».
final class IdleChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var idleChannels: [ObjectIdentifier: any Channel] = [:]

    func register(_ channel: any Channel) {
        let id = ObjectIdentifier(channel)
        lock.lock(); idleChannels[id] = channel; lock.unlock()
    }

    func unregister(_ channel: any Channel) {
        let id = ObjectIdentifier(channel)
        lock.lock(); idleChannels.removeValue(forKey: id); lock.unlock()
    }

    func snapshot() -> [any Channel] {
        lock.lock(); defer { lock.unlock() }
        return Array(idleChannels.values)
    }
}

final class FakeIMAPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = IMAPLine
    typealias OutboundOut = IMAPLine

    private let signals: ServerSignals
    private let idleRegistry: IdleChannelRegistry

    /// Состояние соединения.
    private var inIdle = false
    private var idleTag: String?
    private var loggedIn = false
    private var selectedMailbox: String?
    /// Текущее `EXISTS` в активной папке. Меняется когда сервер «получил» письмо.
    private var existsCount: UInt32 = 3
    private var uidNext: UInt32 = 4

    init(signals: ServerSignals, idleRegistry: IdleChannelRegistry) {
        self.signals = signals
        self.idleRegistry = idleRegistry
    }

    func channelActive(context: ChannelHandlerContext) {
        write(context, "* OK IMAP4rev1 fake server ready")
        context.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !signals.logoutSeen {
            // Соединение закрылось без LOGOUT — фиксируем для проверки cancel.
            signals.markChannelClosed()
        }
        idleRegistry.unregister(context.channel)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let raw = unwrapInboundIn(data).raw

        // Внутри IDLE-режима ожидаем только DONE (и финальный tagged OK).
        if inIdle {
            if raw.uppercased() == "DONE" {
                signals.markDone()
                let tag = idleTag ?? "*"
                inIdle = false
                idleTag = nil
                idleRegistry.unregister(context.channel)
                write(context, "\(tag) OK IDLE terminated")
                context.flush()
            }
            return
        }

        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count >= 2 else {
            write(context, "\(parts.first ?? "*") BAD malformed")
            context.flush()
            return
        }
        let tag = parts[0]
        let cmd = parts[1]
        let upper = cmd.uppercased()

        if upper.hasPrefix("CAPABILITY") {
            write(context, "* CAPABILITY IMAP4rev1 IDLE")
            write(context, "\(tag) OK CAPABILITY completed")
        } else if upper.hasPrefix("LOGIN") {
            loggedIn = true
            write(context, "\(tag) OK LOGIN completed")
        } else if upper.hasPrefix("LIST") {
            write(context, "* LIST (\\HasNoChildren) \"/\" \"INBOX\"")
            write(context, "\(tag) OK LIST completed")
        } else if upper.hasPrefix("SELECT") {
            // SELECT "INBOX" → отдаём базовые untagged + tagged OK [READ-WRITE].
            selectedMailbox = "INBOX"
            write(context, "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)")
            write(context, "* \(existsCount) EXISTS")
            write(context, "* 0 RECENT")
            write(context, "* OK [UIDVALIDITY 1] UIDs valid")
            write(context, "* OK [UIDNEXT \(uidNext)] Predicted next UID")
            write(context, "\(tag) OK [READ-WRITE] SELECT completed")
        } else if upper == "IDLE" {
            inIdle = true
            idleTag = tag
            idleRegistry.register(context.channel)
            write(context, "+ idling")
            context.flush()
            signals.markIdleStarted()
            return
        } else if upper.hasPrefix("UID FETCH") {
            // Минимальный FETCH для diff: отдаём по одной FETCH-записи на UID
            // в диапазоне [1...uidNext-1]. Тело письма не передаём — только
            // метаданные (UID/FLAGS/INTERNALDATE/SIZE/ENVELOPE/BODYSTRUCTURE).
            let upperBound = max(uidNext - 1, 0)
            if upperBound >= 1 {
                for uid in 1...upperBound {
                    write(context, Self.fetchLine(seq: uid, uid: uid))
                }
            }
            write(context, "\(tag) OK FETCH completed")
        } else if upper.hasPrefix("LOGOUT") {
            signals.markLogout()
            write(context, "* BYE")
            write(context, "\(tag) OK LOGOUT completed")
            context.flush()
            _ = context.close()
            return
        } else {
            // Безопасный default — не проваливаем сессию.
            write(context, "\(tag) OK")
        }
        context.flush()
    }

    private func write(_ context: ChannelHandlerContext, _ line: String) {
        context.write(wrapOutboundOut(IMAPLine(line)), promise: nil)
    }

    static func fetchLine(seq: UInt32, uid: UInt32) -> String {
        let envelope = """
        ENVELOPE ("Tue, 17 Apr 2026 10:30:42 +0300" "Subject \(uid)" \
        (("Alice" NIL "alice" "example.com")) \
        (("Alice" NIL "alice" "example.com")) \
        (("Alice" NIL "alice" "example.com")) \
        (("Bob" NIL "bob" "example.com")) \
        NIL NIL NIL "<msg-\(uid)@example.com>")
        """
        let body = "BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 256 5)"
        return "* \(seq) FETCH (UID \(uid) FLAGS (\\Seen) " +
            "INTERNALDATE \"17-Apr-2026 10:30:42 +0300\" RFC822.SIZE 1024 \(envelope) \(body))"
    }
}

actor FakeServer {
    let port: Int
    let signals: ServerSignals
    let idleRegistry: IdleChannelRegistry
    private let channel: any Channel

    static func start(on group: MultiThreadedEventLoopGroup) async throws -> FakeServer {
        let signals = ServerSignals()
        let registry = IdleChannelRegistry()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(FakeIMAPServerHandler(signals: signals, idleRegistry: registry))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return FakeServer(
            port: ch.localAddress!.port!,
            channel: ch,
            signals: signals,
            idleRegistry: registry
        )
    }

    private init(
        port: Int,
        channel: any Channel,
        signals: ServerSignals,
        idleRegistry: IdleChannelRegistry
    ) {
        self.port = port
        self.channel = channel
        self.signals = signals
        self.idleRegistry = idleRegistry
    }

    /// Толкает `* N EXISTS` всем соединениям, находящимся в IDLE.
    func pushExists(_ count: UInt32) async throws {
        for ch in idleRegistry.snapshot() {
            try await ch.writeAndFlush(IMAPLine("* \(count) EXISTS")).get()
        }
    }

    /// Толкает «пульс» — `* OK Still here` всем IDLE-соединениям. Нужен чтобы
    /// `iterator.next()` на стороне клиента вернулся и `Task.checkCancellation()`
    /// мог сработать (NIO async iterator не cancellable сам по себе).
    func pulse() async throws {
        for ch in idleRegistry.snapshot() {
            try await ch.writeAndFlush(IMAPLine("* OK Still here")).get()
        }
    }

    /// Принудительно закрывает все клиентские соединения, висящие в IDLE.
    /// Используется в smoke для проверки инварианта «cancel → connection closed»:
    /// фейковый разрыв сети заставляет клиентский iterator вернуть EOF и
    /// background task IDLE-контроллера корректно завершиться.
    func closeIdleConnections() async {
        for ch in idleRegistry.snapshot() {
            try? await ch.close()
        }
    }

    func stop() async throws { try await channel.close() }
}

// MARK: - Smoke runner

@main
enum SessionPoolIDLESmokeRunner {
    static func main() async throws {
        try await runSmoke()
    }
}

func runSmoke() async throws {
    let group = MultiThreadedEventLoopGroup.singleton
    let server = try await FakeServer.start(on: group)
    let port = server.port
    let signals = server.signals
    log("▶ fake IMAP server: 127.0.0.1:\(port)")

    let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, security: .plain)

    // 1. Командная сессия (Pool-2).
    let session = IMAPSession(
        endpoint: endpoint,
        username: "alice",
        password: "stub",
        eventLoopGroup: group
    )
    try await session.start()
    let readyState = await session.state
    check("IMAPSession state == .ready после start()", readyState == .ready)

    // SELECT INBOX через сессию — чтобы знать стартовый uidNext.
    let initialSelect = try await session.select("INBOX")
    check("SELECT INBOX вернул EXISTS=3", initialSelect.exists == 3)
    check("SELECT INBOX вернул UIDNEXT=4", initialSelect.uidNext == 4)
    log("ℹ initial: exists=\(initialSelect.exists) uidNext=\(initialSelect.uidNext ?? 0)")

    // 2. IDLE-контроллер (Pool-3) — отдельное соединение.
    let idle = IMAPIdleController(
        endpoint: endpoint,
        username: "alice",
        password: "stub",
        eventLoopGroup: group,
        tuning: IMAPIdleTuning(idleTimeout: .seconds(60), commandTimeout: .seconds(5))
    )
    try await idle.start()
    try await idle.setMailbox("INBOX")

    // Подписываемся на события до того, как сервер начнёт пушить EXISTS.
    let eventsTask = Task<UInt32?, Never> {
        for await event in idle.events {
            if case .exists(_, let count) = event {
                return count
            }
        }
        return nil
    }

    // Ждём, пока сервер увидит IDLE-команду в idle-канале.
    await signals.waitIdle()
    check("сервер увидел IDLE", signals.idleStarted)

    // 3. Толкаем EXISTS=5 → подписчик в idle.events должен получить событие
    // без ручного refresh. Параллельно потребитель идёт в IMAPSession за diff.
    try await server.pushExists(5)

    // Ждём событие EXISTS с таймаутом.
    let observed = await withTaskGroup(of: UInt32?.self) { group in
        group.addTask { await eventsTask.value }
        group.addTask {
            try? await Task.sleep(for: .seconds(5))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    check("получили событие .exists через AsyncStream без ручного refresh",
          observed == 5)

    // 4. Diff по uidNext — забираем актуальный список через session.
    let refreshed = try await session.select("INBOX")
    let (fetches, parseErrors) = try await session.uidFetchHeaders(
        range: IMAPUIDRange(lower: 1, upper: max((refreshed.uidNext ?? 1) - 1, 1))
    )
    check("FETCH parseErrors == 0", parseErrors == 0)
    check("FETCH вернул хотя бы 1 заголовок (diff после EXISTS)", !fetches.isEmpty)
    log("ℹ refreshed list: \(fetches.count) headers")

    // 5. Cancellation: stop сессии — должен отправить LOGOUT через очередь
    // (на этом канале нет IDLE-блокировки, поэтому iterator активно читает
    // ответы). Проверяем, что LOGOUT действительно ушёл на сервер.
    log("▶ stopping session via session.stop()")
    await withTimeout(seconds: 10, label: "session.stop") {
        await session.stop()
    }
    log("◀ session stopped")
    // Дадим сетевым событиям догнаться (LOGOUT/close идёт асинхронно).
    try? await Task.sleep(for: .milliseconds(300))
    check("LOGOUT отправлен ИЛИ соединение закрыто после session.stop()",
          signals.logoutSeen || signals.channelClosedNonGracefully)

    // 6. Pool-3-fix: idle.stop() должен корректно завершать контроллер даже
    // при простаивающем канале (без принудительного обрыва). Внутри
    // IMAPConnection.idle() стоит withTaskCancellationHandler, который при
    // отмене Task шлёт DONE — сервер отвечает tagged OK и read-цикл выходит.
    log("▶ stopping IDLE controller on idle channel (no server-side close)")
    await withTimeout(seconds: 10, label: "idle.stop") {
        await idle.stop()
    }
    let idleFinalState = await idle.state
    if case .stopped = idleFinalState {
        log("✓ IMAPIdleController state == .stopped без обрыва канала")
    } else {
        die("IMAPIdleController state неожиданный: \(idleFinalState)")
    }
    check("DONE отправлен сервером во время idle.stop() (Pool-3-fix)",
          signals.doneSeen)

    try await server.stop()
    print("✅ SessionPoolIDLESmoke OK")
}
