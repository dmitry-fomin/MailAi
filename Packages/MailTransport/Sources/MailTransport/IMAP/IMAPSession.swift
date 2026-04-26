import Foundation
import NIOCore
import NIOPosix

/// Состояние жизненного цикла IMAP-сессии.
public enum IMAPSessionState: Sendable {
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
    case logout(CheckedContinuation<Void, any Error>)
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
            } catch {
                await self?.setState(.disconnected(error))
                // Завершаем все pending continuation'ы с ошибкой.
                await self?.failAllPending(with: error)
            }
        }
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

    /// Обрабатывает одну команду на соединении.
    private nonisolated func handleCommand(
        _ command: SessionCommand,
        connection: IMAPConnection
    ) async {
        switch command {
        case .mailboxes(let cont):
            do {
                let result = try await connection.list()
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }

        case .select(let mailbox, let cont):
            do {
                let result = try await connection.select(mailbox)
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }

        case .uidFetchHeaders(let range, let attributes, let cont):
            do {
                let result = try await connection.uidFetchHeaders(
                    range: range, attributes: attributes
                )
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }

        case .logout(let cont):
            do {
                try await connection.logout()
                cont.resume(returning: ())
            } catch {
                cont.resume(throwing: error)
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
