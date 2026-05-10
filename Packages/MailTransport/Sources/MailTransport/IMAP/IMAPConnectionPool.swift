import Foundation
import NIOCore
import NIOPosix

// MARK: - Errors

/// Ошибки пула IMAP-соединений.
public enum IMAPConnectionPoolError: Error, Sendable {
    /// Пул уже был запущен.
    case alreadyStarted
    /// Пул остановлен — новые запросы не принимаются.
    case poolClosed
    /// Ожидание свободного соединения превысило `acquireTimeout`.
    case acquireTimeout
}

// MARK: - Configuration

/// Настройки пула соединений.
public struct IMAPConnectionPoolConfig: Sendable {
    /// Минимальное число соединений, поддерживаемых в режиме ожидания.
    public let minConnections: Int
    /// Максимальное число одновременных соединений.
    public let maxConnections: Int
    /// Таймаут ожидания свободного слота в пуле.
    public let acquireTimeout: Duration
    /// Таймаут TCP+TLS-соединения.
    public let connectTimeout: TimeAmount

    public init(
        minConnections: Int = 1,
        maxConnections: Int = 3,
        acquireTimeout: Duration = .seconds(30),
        connectTimeout: TimeAmount = .seconds(10)
    ) {
        precondition(minConnections >= 0)
        precondition(maxConnections >= 1)
        precondition(minConnections <= maxConnections)
        self.minConnections = minConnections
        self.maxConnections = maxConnections
        self.acquireTimeout = acquireTimeout
        self.connectTimeout = connectTimeout
    }

    public static let `default` = IMAPConnectionPoolConfig()
}

// MARK: - Pool

/// Актор, управляющий пулом `IMAPSession` для одного аккаунта.
///
/// Жизненный цикл:
/// 1. `start()` — создаёт `minConnections` соединений параллельно.
/// 2. `withLease { session in ... }` — берёт/создаёт сессию и автоматически
///    возвращает её по завершении блока.
/// 3. `acquire()` / `release(_:)` — ручное управление арендой.
/// 4. `stop()` — останавливает все сессии, будит ожидающих с ошибкой.
///
/// Когда свободных соединений нет и пул заполнен, вызывающий ждёт до
/// `config.acquireTimeout`. По истечении — бросается `IMAPConnectionPoolError.acquireTimeout`.
///
/// **Concurrency**: actor защищает внутреннее состояние; `IMAPSession` тоже
/// actor — вызовы к нему безопасны из любого контекста.
public actor IMAPConnectionPool {

    // MARK: - Public state

    /// Текущее число активных (включая занятые) соединений.
    public private(set) var activeCount: Int = 0

    /// Число соединений, доступных для выдачи прямо сейчас.
    public var availableCount: Int { available.count }

    // MARK: - Config & credentials

    public let config: IMAPConnectionPoolConfig

    // MARK: - Private

    private let endpoint: IMAPEndpoint
    private let username: String
    private let password: String
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    /// Готовые к выдаче сессии.
    private var available: [IMAPSession] = []

    /// Continuation'ы, ожидающие появления свободного слота.
    private var waiters: [WaiterID: CheckedContinuation<IMAPSession, any Error>] = [:]
    private var waiterQueue: [WaiterID] = []
    private var nextWaiterID: UInt64 = 0

    private var started = false
    private var closed = false

    // MARK: - Init

    public init(
        endpoint: IMAPEndpoint,
        username: String,
        password: String,
        config: IMAPConnectionPoolConfig = .default,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton
    ) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.config = config
        self.eventLoopGroup = eventLoopGroup
    }

    // MARK: - Lifecycle

    /// Запускает пул: открывает `minConnections` соединений параллельно.
    ///
    /// Если создание хотя бы одного из минимальных соединений провалится,
    /// выбрасывается ошибка и уже созданные закрываются.
    public func start() async throws {
        guard !started else { throw IMAPConnectionPoolError.alreadyStarted }
        started = true

        guard config.minConnections > 0 else { return }

        var sessions: [IMAPSession] = []
        do {
            try await withThrowingTaskGroup(of: IMAPSession.self) { [endpoint, username, password, eventLoopGroup] group in
                for _ in 0..<config.minConnections {
                    group.addTask {
                        let session = IMAPSession(
                            endpoint: endpoint,
                            username: username,
                            password: password,
                            eventLoopGroup: eventLoopGroup
                        )
                        try await session.start()
                        return session
                    }
                }
                for try await session in group {
                    sessions.append(session)
                }
            }
        } catch {
            for s in sessions { await s.stop() }
            throw error
        }

        available.append(contentsOf: sessions)
        activeCount = sessions.count
    }

    /// Останавливает пул: завершает всех ожидающих с ошибкой, закрывает сессии.
    public func stop() async {
        guard !closed else { return }
        closed = true

        // Будим ожидающих с ошибкой.
        let waiterSnapshot = waiterQueue.compactMap { waiters[$0] }
        waiters.removeAll()
        waiterQueue.removeAll()
        for waiter in waiterSnapshot {
            waiter.resume(throwing: IMAPConnectionPoolError.poolClosed)
        }

        // Закрываем все доступные сессии.
        let sessionsToClose = available
        available.removeAll()
        activeCount = 0
        for session in sessionsToClose {
            await session.stop()
        }
    }

    // MARK: - Acquire / Release

    /// Берёт сессию из пула. Если пул заполнен — ждёт до `acquireTimeout`.
    ///
    /// Возвращённую сессию **необходимо** вернуть через `release(_:)`.
    /// Предпочтительный вариант — `withLease { }`.
    public func acquire() async throws -> IMAPSession {
        guard started else { throw IMAPConnectionPoolError.poolClosed }
        guard !closed else { throw IMAPConnectionPoolError.poolClosed }

        // Есть готовая сессия — выдаём немедленно.
        if !available.isEmpty {
            return available.removeFirst()
        }

        // Лимит не достигнут — создаём новое соединение.
        if activeCount < config.maxConnections {
            activeCount += 1
            do {
                return try await makeSession()
            } catch {
                activeCount -= 1
                throw error
            }
        }

        // Пул полон — встаём в очередь ожидания с таймаутом.
        return try await waitForAvailable()
    }

    /// Возвращает сессию в пул. Мёртвые сессии дропаются.
    public func release(_ session: IMAPSession) async {
        guard !closed else {
            Task.detached { await session.stop() }
            return
        }

        let sessionState = await session.state
        guard case .ready = sessionState else {
            // Сессия мертва.
            activeCount = max(0, activeCount - 1)
            await fulfillNextWaiterOrClose()
            return
        }

        // Передаём ожидающему или кладём в доступные.
        if let nextID = waiterQueue.first, let waiter = waiters[nextID] {
            waiterQueue.removeFirst()
            waiters.removeValue(forKey: nextID)
            waiter.resume(returning: session)
        } else {
            available.append(session)
        }
    }

    // MARK: - Convenience

    /// Берёт сессию, выполняет `body` и автоматически возвращает сессию в пул.
    ///
    /// Сессия возвращается даже при броске исключения.
    ///
    /// ```swift
    /// let messages = try await pool.withLease { session in
    ///     try await session.uidFetchHeaders(range: .all)
    /// }
    /// ```
    public func withLease<R: Sendable>(
        _ body: @Sendable (IMAPSession) async throws -> R
    ) async throws -> R {
        let session = try await acquire()
        do {
            let result = try await body(session)
            await release(session)
            return result
        } catch {
            await release(session)
            throw error
        }
    }

    // MARK: - Private helpers

    private struct WaiterID: Hashable {
        let value: UInt64
    }

    private func makeSession() async throws -> IMAPSession {
        let session = IMAPSession(
            endpoint: endpoint,
            username: username,
            password: password,
            eventLoopGroup: eventLoopGroup
        )
        try await session.start()
        return session
    }

    /// Встаём в очередь ожидания и ждём с таймаутом.
    private func waitForAvailable() async throws -> IMAPSession {
        let id = WaiterID(value: nextWaiterID)
        nextWaiterID &+= 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IMAPSession, any Error>) in
                // actor-изолированный контекст — регистрируем синхронно.
                waiters[id] = cont
                waiterQueue.append(id)

                // Запускаем таймер в фоне; он разбудит нас с ошибкой если
                // никто не отдаст сессию вовремя.
                let timeout = config.acquireTimeout
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutWaiter(id: id)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: id)
            }
        }
    }

    private func timeoutWaiter(id: WaiterID) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        waiterQueue.removeAll { $0 == id }
        cont.resume(throwing: IMAPConnectionPoolError.acquireTimeout)
    }

    private func cancelWaiter(id: WaiterID) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        waiterQueue.removeAll { $0 == id }
        cont.resume(throwing: CancellationError())
    }

    /// Если есть ожидающий — создаём новое соединение и отдаём ему.
    /// Вызывается, когда сессия умерла при возврате.
    private func fulfillNextWaiterOrClose() async {
        guard !closed, !waiterQueue.isEmpty,
              let nextID = waiterQueue.first,
              let waiter = waiters[nextID] else { return }

        guard activeCount < config.maxConnections else {
            // Слотов нет — ожидающий получит сессию когда кто-то вернёт свою.
            return
        }

        waiterQueue.removeFirst()
        waiters.removeValue(forKey: nextID)
        activeCount += 1

        do {
            let session = try await makeSession()
            waiter.resume(returning: session)
        } catch {
            activeCount -= 1
            waiter.resume(throwing: error)
        }
    }
}
