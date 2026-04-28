import Foundation
import NIOCore
import NIOPosix

// MARK: - Public events / state

/// Событие IDLE-канала, видимое потребителям.
///
/// Тело письма не передаём — только метаданные (UID/seq/тип события). Любая
/// детальная синхронизация выполняется потребителем через отдельный канал
/// `IMAPSession`. Это сохраняет инвариант «никакого содержимого в логах/стриме
/// без явной выборки».
public enum IMAPIdleEvent: Sendable, Equatable {
    /// IDLE-цикл активирован для указанной папки.
    case idleStarted(mailbox: String)
    /// IDLE-цикл остановлен (DONE отправлен, ждём перехода/завершения).
    case idleStopped(mailbox: String, reason: StopReason)
    /// Сервер сообщил новое значение EXISTS — пришло одно или несколько писем.
    case exists(mailbox: String, count: UInt32)
    /// Сервер сообщил EXPUNGE — указанный seq удалён.
    case expunge(mailbox: String, seq: UInt32)
    /// Любое другое untagged-событие (RECENT, FETCH-flag-update и т.п.) — для
    /// телеметрии/диагностики. Содержит только тип, без полезной нагрузки.
    case other(mailbox: String, kind: String)

    public enum StopReason: Sendable, Equatable {
        /// 29-минутный таймаут — будет re-IDLE.
        case timeout
        /// Запрошена смена папки.
        case mailboxChange(to: String)
        /// Контроллер останавливается (`stop()` или Task.cancel).
        case shuttingDown
        /// Ошибка — IDLE завершился исключением.
        case failure
    }
}

/// Состояние жизненного цикла контроллера.
public enum IMAPIdleControllerState: Sendable, Equatable {
    case notStarted
    case connecting
    case active(mailbox: String?)
    case stopped((any Error)?)

    public static func == (lhs: IMAPIdleControllerState, rhs: IMAPIdleControllerState) -> Bool {
        switch (lhs, rhs) {
        case (.notStarted, .notStarted), (.connecting, .connecting):
            return true
        case (.active(let a), .active(let b)):
            return a == b
        case (.stopped(let a), .stopped(let b)):
            return (a == nil) == (b == nil)
        default:
            return false
        }
    }
}

public enum IMAPIdleControllerError: Error, Sendable {
    case alreadyStarted
    case notStarted
    case stopped
}

// MARK: - Tunables

/// Тонкие настройки IDLE-цикла.
public struct IMAPIdleTuning: Sendable {
    /// Таймаут IDLE — RFC 2177 рекомендует не дольше 29 минут.
    public let idleTimeout: Duration
    /// Таймаут на одну SELECT-команду / DONE-обмен.
    public let commandTimeout: Duration

    public init(
        idleTimeout: Duration = .seconds(29 * 60),
        commandTimeout: Duration = .seconds(30)
    ) {
        self.idleTimeout = idleTimeout
        self.commandTimeout = commandTimeout
    }

    public static let `default` = IMAPIdleTuning()
}

// MARK: - Once-resumable wrapper

/// Обёртка над `CheckedContinuation<Void, Never>`, гарантирующая однократный
/// `resume()`. Защищает от double-resume краша, когда несколько мест
/// (background loop и `drainPendingAsCancelled`) могут одновременно попытаться
/// завершить одно и то же ожидание.
///
/// Изолирована как `final class` (reference semantics) — несколько владельцев
/// видят одно состояние `resumed`. Не `actor`, чтобы не вводить async hop при
/// вызове `resume()` — флаг `nonisolated(unsafe)` защищён контрактом:
/// `resume()` вызывается строго из actor-изолированных контекстов
/// (`IdleCommandQueue` actor, `IMAPIdleController` actor), поэтому
/// конкурентных обращений нет.
private final class StopWaiter: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ cont: CheckedContinuation<Void, Never>) {
        self.continuation = cont
    }

    /// Резюмирует continuation ровно один раз; повторные вызовы — no-op.
    func resumeOnce() {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume()
    }
}

// MARK: - Internal command queue

/// Внутренняя команда для background loop.
private enum IdleCommand: Sendable {
    case setMailbox(String, CheckedContinuation<Void, any Error>)
    case stop(StopWaiter)
}

/// Простая FIFO-очередь команд с «звоночком» — actor-обёртка над массивом и
/// одним continuation. Нужна, потому что `AsyncStream.Iterator` не Sendable
/// и его нельзя передавать между задачами/группами вместе с другими
/// конкурентными ожиданиями.
private actor IdleCommandQueue {

    /// Результат `next()`: команда, закрытие очереди, либо отмена ожидания.
    enum NextResult: Sendable {
        case command(IdleCommand)
        case closed
        case cancelled
    }

    private var pending: [IdleCommand] = []
    private var waiter: CheckedContinuation<NextResult, Never>?
    private var closed = false

    func push(_ cmd: IdleCommand) -> Bool {
        if closed { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: .command(cmd))
        } else {
            pending.append(cmd)
        }
        return true
    }

    /// Возвращает команду в начало очереди — нужен на случай гонки в
    /// `withTaskGroup`, где «победил» idle/timeout, но `next()` уже успел
    /// вытащить команду. Вызывающая сторона не должна терять её.
    func unshift(_ cmd: IdleCommand) {
        if closed {
            switch cmd {
            case .setMailbox(_, let cont):
                cont.resume(throwing: IMAPIdleControllerError.stopped)
            case .stop(let waiter):
                waiter.resumeOnce()
            }
            return
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: .command(cmd))
        } else {
            pending.insert(cmd, at: 0)
        }
    }

    /// Ожидает следующую команду. Кооперативно реагирует на `Task.cancel()`.
    func next() async -> NextResult {
        if !pending.isEmpty {
            return .command(pending.removeFirst())
        }
        if closed { return .closed }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<NextResult, Never>) in
                self.waiter = cont
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter()
            }
        }
    }

    private func cancelWaiter() {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: .cancelled)
        }
    }

    func close() {
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: .closed)
        }
    }

    func drainPendingAsCancelled() {
        let snapshot = pending
        pending.removeAll()
        for cmd in snapshot {
            switch cmd {
            case .setMailbox(_, let cont):
                cont.resume(throwing: IMAPIdleControllerError.stopped)
            case .stop(let waiter):
                // resumeOnce() гарантирует однократный resume — безопасно даже
                // если background loop уже обработал эту команду.
                waiter.resumeOnce()
            }
        }
    }
}

// MARK: - IMAPIdleController

/// Long-lived actor, держащий ОТДЕЛЬНОЕ IMAP-соединение под IDLE.
///
/// Зачем отдельное соединение? Команда `IDLE` блокирует канал до получения
/// `DONE` — никаких других команд через него выполнить нельзя. Поэтому
/// IDLE-цикл живёт параллельно с обычной командной сессией (`IMAPSession`)
/// и общается с UI через `events: AsyncStream<IMAPIdleEvent>`.
///
/// Жизненный цикл:
///
/// 1. `start()` — открывает соединение и LOGIN.
/// 2. `setMailbox("INBOX")` — SELECT + IDLE.
/// 3. По срабатыванию EXISTS / EXPUNGE — событие в `events`.
///    Потребитель сам решает, нужно ли запускать diff по `uidNext`.
/// 4. По таймауту 29 минут — DONE + IDLE (re-issue на той же папке).
/// 5. По `setMailbox(other)` — DONE → SELECT other → IDLE.
/// 6. По `stop()` или Task.cancel() — DONE → LOGOUT → close.
///
/// Реконнект здесь не делается: при обрыве переходим в `.stopped(error)`,
/// верхний уровень (поставщик данных) пересоздаёт контроллер. Это даёт
/// чистую границу между «жив» и «мёртв» и позволяет переиспользовать
/// логику `IMAPReconnectSupervisor` снаружи.
public actor IMAPIdleController {

    // MARK: - Public state / events

    public private(set) var state: IMAPIdleControllerState = .notStarted

    /// Стрим событий. Потребитель должен подписаться один раз — повторный
    /// итератор поверх `AsyncStream` вернёт пустой поток.
    public nonisolated var events: AsyncStream<IMAPIdleEvent> { _events }

    // MARK: - Private

    private let endpoint: IMAPEndpoint
    private let username: String
    private let password: String
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let tuning: IMAPIdleTuning

    private let _events: AsyncStream<IMAPIdleEvent>
    private let eventsContinuation: AsyncStream<IMAPIdleEvent>.Continuation

    private let queue = IdleCommandQueue()
    private var backgroundTask: Task<Void, Never>?

    private var started = false
    private var startContinuation: CheckedContinuation<Void, any Error>?

    // MARK: - Init

    public init(
        endpoint: IMAPEndpoint,
        username: String,
        password: String,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton,
        tuning: IMAPIdleTuning = .default
    ) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.eventLoopGroup = eventLoopGroup
        self.tuning = tuning
        let (stream, continuation) = AsyncStream<IMAPIdleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self._events = stream
        self.eventsContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Открывает соединение и логинится. Папка ещё не выбрана — для запуска
    /// IDLE необходимо вызвать `setMailbox(_:)`.
    public func start() async throws {
        guard !started else { throw IMAPIdleControllerError.alreadyStarted }
        started = true
        state = .connecting

        let endpoint = self.endpoint
        let eventLoopGroup = self.eventLoopGroup
        let username = self.username
        let password = self.password
        let tuning = self.tuning
        let eventsContinuation = self.eventsContinuation
        let queue = self.queue

        // ВАЖНО: startContinuation устанавливается синхронно внутри замыкания,
        // до запуска backgroundTask — это гарантирует отсутствие гонки, при
        // которой resumeStart() мог бы сработать раньше установки continuation.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.startContinuation = cont
            self.backgroundTask = Task { [weak self] in
                do {
                    try await IMAPConnection.withOpen(
                        endpoint: endpoint,
                        eventLoopGroup: eventLoopGroup
                    ) { conn in
                        try await conn.login(username: username, password: password)
                        await self?.markActive(mailbox: nil)
                        await self?.resumeStart(.success(()))

                        await Self.runLoop(
                            connection: conn,
                            queue: queue,
                            events: eventsContinuation,
                            tuning: tuning,
                            controller: self
                        )

                        try? await conn.logout()
                    }
                    await self?.markStopped(error: nil)
                } catch is CancellationError {
                    await self?.markStopped(error: nil)
                    await self?.resumeStart(.failure(CancellationError()))
                } catch {
                    await self?.markStopped(error: error)
                    await self?.resumeStart(.failure(error))
                }
                await queue.drainPendingAsCancelled()
                eventsContinuation.finish()
            }
        }
    }

    /// Меняет активную папку: завершает текущий IDLE (DONE), делает SELECT
    /// и стартует новый IDLE. Возвращает управление, когда новый IDLE поднят.
    public func setMailbox(_ path: String) async throws {
        if case .stopped = state { throw IMAPIdleControllerError.stopped }
        guard started else { throw IMAPIdleControllerError.notStarted }

        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            Task { [queue] in
                let accepted = await queue.push(.setMailbox(path, waiter))
                if !accepted {
                    waiter.resume(throwing: IMAPIdleControllerError.stopped)
                }
            }
        }
    }

    /// Останавливает контроллер: гарантирует отправку DONE до закрытия канала
    /// и LOGOUT. Безопасно вызывать повторно.
    public func stop() async {
        if !started {
            backgroundTask?.cancel()
            _ = await backgroundTask?.value
            backgroundTask = nil
            return
        }
        if case .stopped = state {
            _ = await backgroundTask?.value
            backgroundTask = nil
            return
        }
        await withCheckedContinuation { (rawWaiter: CheckedContinuation<Void, Never>) in
            let waiter = StopWaiter(rawWaiter)
            Task { [queue] in
                let accepted = await queue.push(.stop(waiter))
                if !accepted {
                    waiter.resumeOnce()
                }
            }
        }
        await queue.close()
        _ = await backgroundTask?.value
        backgroundTask = nil
    }

    // MARK: - Actor helpers (вызываются из background task)

    private func resumeStart(_ result: Result<Void, any Error>) {
        guard let cont = startContinuation else { return }
        startContinuation = nil
        cont.resume(with: result)
    }

    private func markActive(mailbox: String?) {
        state = .active(mailbox: mailbox)
    }

    private func markStopped(error: (any Error)?) {
        state = .stopped(error)
    }

    // MARK: - Background loop

    private enum LoopAction: Sendable {
        case timeout
        case command(IdleCommand)
        case idleFinished(Result<Void, IdleErrorBox>)
        case commandsClosed
    }

    /// Sendable-обёртка для ошибки IDLE — сам `any Error` не Sendable.
    private struct IdleErrorBox: Error, Sendable {
        let description: String
    }

    /// Главный цикл: SELECT + IDLE с 29-минутным таймаутом и реакцией на
    /// смену папки / stop. Все эффекты на actor — через `await controller?`.
    private static func runLoop(
        connection: IMAPConnection,
        queue: IdleCommandQueue,
        events: AsyncStream<IMAPIdleEvent>.Continuation,
        tuning: IMAPIdleTuning,
        controller: IMAPIdleController?
    ) async {
        var currentMailbox: String?

        loop: while !Task.isCancelled {
            // Если папки нет — просто ждём команду.
            if currentMailbox == nil {
                let next = await queue.next()
                guard case .command(let cmd) = next else { break loop }
                switch cmd {
                case .setMailbox(let path, let waiter):
                    do {
                        _ = try await connection.select(path)
                        currentMailbox = path
                        await controller?.markActive(mailbox: path)
                        waiter.resume()
                    } catch {
                        waiter.resume(throwing: error)
                        break loop
                    }
                case .stop(let waiter):
                    waiter.resumeOnce()
                    break loop
                }
                continue
            }

            // Папка есть — поднимаем IDLE с таймаутом и слушаем команды.
            let mailbox = currentMailbox!
            events.yield(.idleStarted(mailbox: mailbox))

            // Запускаем IDLE как дочернюю задачу — её можно отменить
            // как по таймауту, так и при поступлении внешней команды.
            // `IMAPConnection.idle` ловит CancellationError и шлёт DONE,
            // ждёт финальный tagged OK — поэтому отмена корректна.
            let idleTask = Task<Void, any Error> {
                _ = try await connection.idle { untagged in
                    Self.dispatchUntagged(untagged, mailbox: mailbox, events: events)
                }
            }

            let action = await Self.waitForFirst(
                queue: queue,
                idleTask: idleTask,
                idleTimeout: tuning.idleTimeout
            )

            switch action {
            case .timeout:
                idleTask.cancel()
                _ = try? await idleTask.value
                events.yield(.idleStopped(mailbox: mailbox, reason: .timeout))
                // currentMailbox остаётся прежним — re-IDLE на следующей итерации.

            case .command(.setMailbox(let path, let waiter)):
                idleTask.cancel()
                _ = try? await idleTask.value
                events.yield(.idleStopped(mailbox: mailbox, reason: .mailboxChange(to: path)))
                if path == mailbox {
                    waiter.resume()
                    continue
                }
                do {
                    _ = try await connection.select(path)
                    currentMailbox = path
                    await controller?.markActive(mailbox: path)
                    waiter.resume()
                } catch {
                    waiter.resume(throwing: error)
                    break loop
                }

            case .command(.stop(let waiter)):
                idleTask.cancel()
                _ = try? await idleTask.value
                events.yield(.idleStopped(mailbox: mailbox, reason: .shuttingDown))
                waiter.resumeOnce()
                break loop

            case .idleFinished(.success):
                events.yield(.idleStopped(mailbox: mailbox, reason: .timeout))
                // Re-IDLE на следующей итерации.

            case .idleFinished(.failure):
                events.yield(.idleStopped(mailbox: mailbox, reason: .failure))
                break loop

            case .commandsClosed:
                idleTask.cancel()
                _ = try? await idleTask.value
                events.yield(.idleStopped(mailbox: mailbox, reason: .shuttingDown))
                break loop
            }
        }
    }

    /// Парсит untagged-ответ и публикует соответствующее событие.
    /// Не логирует содержимое — только числа и тип.
    private static func dispatchUntagged(
        _ untagged: IMAPUntaggedResponse,
        mailbox: String,
        events: AsyncStream<IMAPIdleEvent>.Continuation
    ) {
        // EXISTS / EXPUNGE приходят как «* <num> EXISTS» / «* <num> EXPUNGE»,
        // т.е. в `untagged.raw` первая часть — число.
        if let parsed = Self.parseNumericUntagged(untagged.raw) {
            switch parsed.tag.uppercased() {
            case "EXISTS":
                events.yield(.exists(mailbox: mailbox, count: parsed.value))
            case "EXPUNGE":
                events.yield(.expunge(mailbox: mailbox, seq: parsed.value))
            default:
                events.yield(.other(mailbox: mailbox, kind: parsed.tag))
            }
        } else {
            events.yield(.other(mailbox: mailbox, kind: untagged.kind))
        }
    }

    /// Разбирает untagged вида «<число> <ТЕГ>». Возвращает nil, если форма
    /// другая (например, «CAPABILITY ...»).
    private static func parseNumericUntagged(_ raw: String) -> (value: UInt32, tag: String)? {
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        guard let value = UInt32(parts[0]) else { return nil }
        let tagPart = parts[1].split(separator: " ", maxSplits: 1).first.map(String.init) ?? String(parts[1])
        return (value, tagPart)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func waitForFirst(
        queue: IdleCommandQueue,
        idleTask: Task<Void, any Error>,
        idleTimeout: Duration
    ) async -> LoopAction {
        // Собираем все результаты, чтобы не потерять команду при гонке.
        let results: [LoopAction] = await withTaskGroup(of: LoopAction.self) { group in
            group.addTask {
                switch await queue.next() {
                case .command(let cmd):
                    return .command(cmd)
                case .closed:
                    return .commandsClosed
                case .cancelled:
                    // Группа отменила нас — это значит другая ветка победила.
                    // Возвращаем нейтральное значение, оно отфильтруется
                    // в приоритетной агрегации.
                    return .timeout
                }
            }
            group.addTask {
                // Pool-3-fix: при group.cancelAll() Task.value не реагирует на
                // отмену ожидающего — пробрасываем cancel в idleTask явно.
                await withTaskCancellationHandler {
                    do { _ = try await idleTask.value; return .idleFinished(.success(())) }
                    catch is CancellationError { return .idleFinished(.success(())) }
                    catch { return .idleFinished(.failure(IdleErrorBox(description: String(describing: error)))) }
                } onCancel: { idleTask.cancel() }
            }
            group.addTask {
                try? await Task.sleep(for: idleTimeout)
                return .timeout
            }

            guard let first = await group.next() else { return [] }
            group.cancelAll()
            // Дочитываем оставшиеся результаты — нам важно не потерять
            // `.command(...)`, если он успел отдиспатчиться.
            var collected: [LoopAction] = [first]
            while let next = await group.next() {
                collected.append(next)
            }
            return collected
        }

        // Приоритет — команды (их нельзя потерять), затем timeout/idle.
        var commandHit: LoopAction?
        var nonCommand: LoopAction = .timeout
        var sawCommandsClosed = false
        var sawIdle: LoopAction?
        var sawTimeout = false
        for r in results {
            switch r {
            case .command:
                if commandHit == nil {
                    commandHit = r
                } else if case .command(let cmd) = r {
                    // Двойной хит невозможен (один `next()` task), но на всякий
                    // случай возвращаем в очередь.
                    await queue.unshift(cmd)
                }
            case .commandsClosed:
                sawCommandsClosed = true
            case .idleFinished:
                sawIdle = r
            case .timeout:
                sawTimeout = true
            }
        }
        if let commandHit { return commandHit }
        // Ошибка IDLE важнее таймаута: нужно прервать цикл и сообщить об ошибке,
        // а не делать бесполезный re-IDLE на разорванном соединении.
        if case .idleFinished(.failure) = sawIdle { return sawIdle! }
        if sawTimeout { return .timeout }
        if let sawIdle { return sawIdle }
        if sawCommandsClosed { return .commandsClosed }
        return nonCommand
    }
}
