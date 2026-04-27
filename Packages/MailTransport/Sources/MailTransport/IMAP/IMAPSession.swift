import Foundation
import NIOCore
import NIOPosix

/// Состояние жизненного цикла IMAP-сессии.
public enum IMAPSessionState: Sendable, Equatable {
    /// Сессия создана, но `start()` ещё не вызывался.
    case idle
    /// Открываем TCP+TLS соединение.
    case connecting
    /// Отправляем LOGIN.
    case authenticating
    /// Авторизованы, готовы обрабатывать команды.
    case ready
    /// Соединение потеряно или закрыто. Ошибка — nil при явном `stop()`.
    case disconnected((any Error)?)

    public static func == (lhs: IMAPSessionState, rhs: IMAPSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting),
             (.authenticating, .authenticating), (.ready, .ready):
            return true
        case (.disconnected(let a), .disconnected(let b)):
            return (a == nil) == (b == nil)
        default:
            return false
        }
    }
}

// MARK: - Errors

/// Ошибки IMAPSession.
public enum IMAPSessionError: Error, Sendable {
    /// Сессия не в состоянии, допускающем данную операцию.
    case invalidState(String)
    /// `start()` уже был вызван.
    case alreadyStarted
    /// Сессия разорвана — новые команды не принимаются.
    case sessionClosed(underlying: String)
}

// MARK: - Internal command representation

/// Внутренняя команда для command loop.
/// Каждая несёт `CheckedContinuation` для возврата результата вызвавшему.
private enum SessionCommand: Sendable {
    case mailboxes(CheckedContinuation<[ListEntry], any Error>)
    case select(
        mailbox: String,
        CheckedContinuation<SelectResult, any Error>
    )
    case uidFetchHeaders(
        range: IMAPUIDRange,
        attributes: String,
        CheckedContinuation<(fetches: [IMAPFetchResponse], parseErrors: Int), any Error>
    )
    case uidStore(
        uid: UInt32,
        operation: IMAPConnection.StoreOperation,
        flags: [IMAPConnection.StandardFlag],
        CheckedContinuation<IMAPCommandResult, any Error>
    )
    case expunge(CheckedContinuation<Void, any Error>)
    case uidMove(
        uid: UInt32,
        to: String,
        CheckedContinuation<Void, any Error>
    )
    case uidMoveFallback(
        uid: UInt32,
        to: String,
        CheckedContinuation<Void, any Error>
    )
    case capability(CheckedContinuation<[String], any Error>)
    case fetchBody(
        uid: UInt32,
        section: String,
        CheckedContinuation<[UInt8], any Error>
    )
    case logout(CheckedContinuation<Void, any Error>)
    case append(AppendArgs, CheckedContinuation<Void, any Error>)
}

/// Аргументы IMAP APPEND-команды (вынесены в struct, чтобы не плодить
/// associated values в `SessionCommand.append`).
private struct AppendArgs: Sendable {
    let mailbox: String
    let flags: [String]
    let date: String?
    let literal: String
}

// MARK: - IMAPSession

/// Long-lived actor, держащий одно IMAP-соединение.
///
/// Команды (`mailboxes`, `select`, `uidFetchHeaders`, `logout`) ставятся
/// в очередь через внутренний `AsyncStream` и обрабатываются последовательно
/// в фоне. Соединение открывается один раз при `start()` и закрывается
/// при `stop()` или отмене Task.
///
/// Реконнект — зона ответственности `IMAPReconnectSupervisor`,
/// который оборачивает весь жизненный цикл сессии.
public actor IMAPSession {

    // MARK: - Public state

    /// Текущее состояние сессии (thread-safe через actor isolation).
    public private(set) var state: IMAPSessionState = .idle

    // MARK: - Private properties

    private let endpoint: IMAPEndpoint
    private let username: String
    private let password: String
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    /// Канал для передачи команд в background task.
    private var commandContinuation: AsyncStream<SessionCommand>.Continuation?
    /// Background Task, держащий соединение и обрабатывающий команды.
    private var backgroundTask: Task<Void, Never>?

    /// Защита от повторного `start()`.
    private var started = false

    /// Continuation, который резюмируется когда сессия достигает `.ready`
    /// или `.disconnected(error)`. Используется чтобы `start()` дожидался
    /// готовности соединения.
    private var startContinuation: CheckedContinuation<Void, any Error>?

    // MARK: - Init

    public init(
        endpoint: IMAPEndpoint,
        username: String,
        password: String,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton
    ) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.eventLoopGroup = eventLoopGroup
    }

    // MARK: - Lifecycle

    /// Открывает соединение, логинится и запускает command loop.
    /// Можно вызвать только один раз.
    public func start() async throws {
        guard !started else {
            throw IMAPSessionError.alreadyStarted
        }
        started = true
        state = .connecting

        // Создаём command stream и запоминаем continuation для enqueue.
        let (stream, continuation) = AsyncStream<SessionCommand>.makeStream()
        self.commandContinuation = continuation

        // Запускаем background task, который держит соединение.
        let endpoint = self.endpoint
        let eventLoopGroup = self.eventLoopGroup
        let username = self.username
        let password = self.password

        self.backgroundTask = Task { [weak self] in
            do {
                try await IMAPConnection.withOpen(
                    endpoint: endpoint,
                    eventLoopGroup: eventLoopGroup
                ) { conn in
                    // Фаза аутентификации.
                    await self?.setState(.authenticating)
                    try await conn.login(username: username, password: password)
                    await self?.setState(.ready)
                    await self?.resumeStart(.success(()))

                    // Command loop: читаем команды из stream пока он не завершится.
                    for await command in stream {
                        guard !Task.isCancelled else { return }
                        await self?.handleCommand(command, connection: conn)
                    }

                    // Stream закрыт → отправляем LOGOUT.
                    try? await conn.logout()
                }
            } catch is CancellationError {
                await self?.setState(.disconnected(nil))
                await self?.resumeStart(.failure(CancellationError()))
            } catch {
                await self?.setState(.disconnected(error))
                await self?.resumeStart(.failure(error))
                // Завершаем все pending continuation'ы с ошибкой.
                await self?.failAllPending(with: error)
            }
        }

        // Ждём, пока background task достигнет .ready или упадёт с ошибкой.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.startContinuation = cont
        }
    }

    /// Резюмирует `startContinuation` (если он установлен). Безопасно
    /// при повторных вызовах — continuation очищается после первого.
    private func resumeStart(_ result: Result<Void, any Error>) {
        guard let cont = startContinuation else { return }
        startContinuation = nil
        cont.resume(with: result)
    }

    /// Останавливает сессию: закрывает command stream,(background task
    /// отправит LOGOUT и закроет соединение).
    public func stop() async {
        commandContinuation?.finish()
        commandContinuation = nil
        backgroundTask?.cancel()
        // Ждём завершения background task (он установит .disconnected).
        _ = await backgroundTask?.value
        backgroundTask = nil
    }

    // MARK: - Public command API

    /// Возвращает список почтовых ящиков (IMAP LIST).
    public func mailboxes() async throws -> [ListEntry] {
        try await enqueueCommand { continuation in
            .mailboxes(continuation)
        }
    }

    /// Выбирает почтовый ящик (IMAP SELECT).
    public func select(_ mailbox: String) async throws -> SelectResult {
        try await enqueueCommand { continuation in
            .select(mailbox: mailbox, continuation)
        }
    }

    /// Загружает заголовки писем по диапазону UID (IMAP UID FETCH).
    public func uidFetchHeaders(
        range: IMAPUIDRange,
        attributes: String = IMAPFetchAttributes.headers
    ) async throws -> (fetches: [IMAPFetchResponse], parseErrors: Int) {
        try await enqueueCommand { continuation in
            .uidFetchHeaders(range: range, attributes: attributes, continuation)
        }
    }

    /// Алиас для `mailboxes()` — IMAP LIST.
    public func list() async throws -> [ListEntry] {
        try await mailboxes()
    }

    /// UID STORE — изменяет флаги письма (RFC 3501 STORE).
    public func uidStore(
        uid: UInt32,
        operation: IMAPConnection.StoreOperation,
        flags: [IMAPConnection.StandardFlag]
    ) async throws -> IMAPCommandResult {
        try await enqueueCommand { continuation in
            .uidStore(uid: uid, operation: operation, flags: flags, continuation)
        }
    }

    /// EXPUNGE — физическое удаление писем с флагом \Deleted.
    public func expunge() async throws {
        try await enqueueCommand { continuation in
            .expunge(continuation)
        }
    }

    /// UID MOVE (RFC 6851) — атомарное перемещение.
    public func uidMove(uid: UInt32, to destination: String) async throws {
        try await enqueueCommand { continuation in
            .uidMove(uid: uid, to: destination, continuation)
        }
    }

    /// Fallback-перемещение для серверов без MOVE: COPY + STORE + EXPUNGE.
    public func uidMoveFallback(uid: UInt32, to destination: String) async throws {
        try await enqueueCommand { continuation in
            .uidMoveFallback(uid: uid, to: destination, continuation)
        }
    }

    /// CAPABILITY — список поддерживаемых расширений сервера.
    public func capability() async throws -> [String] {
        try await enqueueCommand { continuation in
            .capability(continuation)
        }
    }

    /// Собирает всё тело письма в память (UID FETCH BODY.PEEK[]).
    /// Чанки собираются внутри command loop и возвращаются единым массивом.
    /// Не использовать для больших вложений — в этом случае нужно
    /// временное соединение через `withSession`.
    public func fetchBody(uid: UInt32, section: String = "") async throws -> [UInt8] {
        try await enqueueCommand { continuation in
            .fetchBody(uid: uid, section: section, continuation)
        }
    }

    /// APPEND (RFC 3501 §6.3.11) — кладёт raw-сообщение в указанный mailbox.
    /// Используется для сохранения черновиков в Drafts. Тело передаётся как
    /// IMAP-literal, сервер обязан принять `\r\n` внутри.
    public func append(
        mailbox: String,
        flags: [String] = [],
        date: String? = nil,
        literal: String
    ) async throws {
        let args = AppendArgs(mailbox: mailbox, flags: flags, date: date, literal: literal)
        try await enqueueCommand { continuation in
            .append(args, continuation)
        }
    }

    /// Явный LOGOUT через command queue (в отличие от `stop()` который
    /// отменяет Task). Полезен для graceful shutdown: LOGOUT отправится
    /// после завершения всех предыдущих команд.
    public func logout() async throws {
        try await enqueueCommand { continuation in
            .logout(continuation)
        }
    }

    // MARK: - Private helpers

    /// Общая функция enqueue: проверяет состояние, создаёт continuation,
    /// отправляет команду в stream и ждёт результат.
    private func enqueueCommand<T: Sendable>(
        _ makeCommand: (CheckedContinuation<T, any Error>) -> SessionCommand
    ) async throws -> T {
        switch state {
        case .ready:
            break
        case .disconnected(let error):
            let msg = error.map { String(describing: $0) } ?? "explicitly closed"
            throw IMAPSessionError.sessionClosed(underlying: msg)
        case .idle, .connecting, .authenticating:
            throw IMAPSessionError.invalidState(String(describing: state))
        }

        guard let continuation = commandContinuation else {
            throw IMAPSessionError.sessionClosed(underlying: "no command channel")
        }

        return try await withCheckedThrowingContinuation { cont in
            let command = makeCommand(cont)
            switch continuation.yield(command) {
            case .enqueued:
                break
            case .dropped, .terminated:
                // Stream уже закрыт — немедленно резюмируем с ошибкой.
                cont.resume(throwing: IMAPSessionError.sessionClosed(
                    underlying: "command stream closed"
                ))
            @unknown default:
                cont.resume(throwing: IMAPSessionError.sessionClosed(
                    underlying: "command stream closed"
                ))
            }
        }
    }

    /// Прокидывает результат `work()` в continuation, при ошибке — её же.
    private nonisolated func bridge<T>(
        _ cont: CheckedContinuation<T, any Error>,
        _ work: () async throws -> T
    ) async {
        do {
            cont.resume(returning: try await work())
        } catch {
            cont.resume(throwing: error)
        }
    }

    /// Обрабатывает одну команду на соединении.
    private nonisolated func handleCommand(
        _ command: SessionCommand,
        connection: IMAPConnection
    ) async {
        switch command {
        case .mailboxes(let cont):
            await bridge(cont) { try await connection.list() }
        case .select(let mailbox, let cont):
            await bridge(cont) { try await connection.select(mailbox) }
        case .uidFetchHeaders(let range, let attributes, let cont):
            await bridge(cont) {
                try await connection.uidFetchHeaders(range: range, attributes: attributes)
            }
        case .uidStore(let uid, let operation, let flags, let cont):
            await bridge(cont) {
                try await connection.uidStore(uid: uid, operation: operation, flags: flags)
            }
        case .expunge(let cont):
            await bridge(cont) { try await connection.expunge() }
        case .uidMove(let uid, let to, let cont):
            await bridge(cont) { try await connection.uidMove(uid: uid, to: to) }
        case .uidMoveFallback(let uid, let to, let cont):
            await bridge(cont) { try await connection.uidMoveFallback(uid: uid, to: to) }
        case .capability(let cont):
            await bridge(cont) { try await connection.capability() }
        case .fetchBody(let uid, let section, let cont):
            await bridge(cont) { try await connection.fetchBody(uid: uid, section: section) }
        case .logout(let cont):
            await bridge(cont) { try await connection.logout() }
        case .append(let args, let cont):
            await bridge(cont) {
                try await connection.append(
                    mailbox: args.mailbox,
                    flags: args.flags,
                    date: args.date,
                    literal: args.literal
                )
            }
        }
    }

    /// Устанавливает состояние сессии (вызывается из background task).
    private func setState(_ newState: IMAPSessionState) {
        state = newState
    }

    /// Завершает все pending continuation'ы ошибкой. Вызывается при
    /// обрыве соединения, чтобы зовущие не зависли навсегда.
    private func failAllPending(with error: any Error) {
        commandContinuation?.finish()
        commandContinuation = nil
    }
}
