import Foundation
import NIOCore
import NIOPosix

// MARK: - IMAPIdleSupervisor

/// Надстройка над `IMAPIdleController` с автоматическим reconnect при обрыве.
///
/// `IMAPIdleController` сам по себе не делает reconnect: при ошибке он
/// переходит в `.stopped(error)` и требует пересоздания. `IMAPIdleSupervisor`
/// оборачивает этот жизненный цикл — при каждом обрыве создаёт новый
/// контроллер и поднимает IDLE заново, используя `IMAPReconnectSupervisor`
/// для экспоненциального backoff.
///
/// События всех контроллеров транслируются в единый `events: AsyncStream`.
///
/// Жизненный цикл:
/// 1. `start(mailbox:)` — запускает петлю reconnect + IDLE для указанной папки.
/// 2. `changeMailbox(_:)` — переключает папку (DONE → SELECT → IDLE).
/// 3. `stop()` — останавливает супервайзер.
///
/// Для использования из AppShell / LiveAccountDataProvider.
public actor IMAPIdleSupervisor {

    // MARK: - Public state

    /// Текущее состояние супервайзера.
    public private(set) var isRunning: Bool = false

    /// Единый поток событий. Не закрывается при reconnect — потребитель
    /// видит непрерывный поток с `.idleStarted` после каждого reconnect.
    public nonisolated var events: AsyncStream<IMAPIdleEvent> { _events }

    // MARK: - Private

    private let endpoint: IMAPEndpoint
    private let username: String
    private let password: String
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let tuning: IMAPIdleTuning
    private let reconnectBackoff: ExponentialBackoff

    private let _events: AsyncStream<IMAPIdleEvent>
    private let eventsContinuation: AsyncStream<IMAPIdleEvent>.Continuation

    /// Текущая активная папка.
    private var currentMailbox: String?

    /// Фоновая задача reconnect-петли.
    private var supervisorTask: Task<Void, Never>?

    /// Ссылка на текущий контроллер — нужна для `changeMailbox`.
    private var activeController: IMAPIdleController?

    // MARK: - Init

    public init(
        endpoint: IMAPEndpoint,
        username: String,
        password: String,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton,
        tuning: IMAPIdleTuning = .default,
        reconnectBackoff: ExponentialBackoff = ExponentialBackoff()
    ) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.eventLoopGroup = eventLoopGroup
        self.tuning = tuning
        self.reconnectBackoff = reconnectBackoff

        let (stream, continuation) = AsyncStream<IMAPIdleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        self._events = stream
        self.eventsContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Запускает IDLE для указанной папки. Reconnect происходит автоматически.
    public func start(mailbox: String) async {
        guard !isRunning else { return }
        isRunning = true
        currentMailbox = mailbox

        let endpoint = self.endpoint
        let username = self.username
        let password = self.password
        let eventLoopGroup = self.eventLoopGroup
        let tuning = self.tuning
        let backoff = self.reconnectBackoff
        let eventsContinuation = self.eventsContinuation

        supervisorTask = Task { [weak self] in
            guard let strongSelf = self else { return }
            let supervisor = IMAPReconnectSupervisor(backoff: backoff)

            try? await supervisor.run { [weak strongSelf] in
                guard let supervisor = strongSelf, !Task.isCancelled else {
                    throw CancellationError()
                }

                let mailbox = await supervisor.currentMailbox ?? "INBOX"

                let controller = IMAPIdleController(
                    endpoint: endpoint,
                    username: username,
                    password: password,
                    eventLoopGroup: eventLoopGroup,
                    tuning: tuning
                )

                await supervisor.setActiveController(controller)

                do {
                    try await controller.start()
                    try await controller.setMailbox(mailbox)
                } catch {
                    await supervisor.clearActiveController()
                    throw error
                }

                // Транслируем события текущего контроллера в общий поток.
                for await event in controller.events {
                    eventsContinuation.yield(event)
                }

                // Контроллер остановился — проверяем, это плановое завершение
                // или обрыв. При остановке супервайзера — выходим.
                await supervisor.clearActiveController()
                let controllerState = await controller.state
                if case .stopped(.some) = controllerState {
                    // Ошибка → reconnect (через throw).
                    throw IMAPIdleControllerError.stopped
                }
                // Плановая остановка (stop() вызван) → выходим из петли.
                throw CancellationError()
            }

            await self?.markStopped()
        }
    }

    /// Переключает активную папку.
    ///
    /// Если контроллер активен — делегирует `setMailbox` ему.
    /// Если контроллер ещё не поднялся (reconnect) — сохраняет имя и он
    /// поднимет IDLE уже в новой папке.
    public func changeMailbox(_ mailbox: String) async throws {
        currentMailbox = mailbox
        if let controller = activeController {
            try await controller.setMailbox(mailbox)
        }
    }

    /// Останавливает супервайзер. Блокирует до полного завершения.
    public func stop() async {
        guard isRunning else { return }
        supervisorTask?.cancel()
        if let controller = activeController {
            await controller.stop()
        }
        _ = await supervisorTask?.value
        supervisorTask = nil
        activeController = nil
        isRunning = false
        eventsContinuation.finish()
    }

    // MARK: - Private

    private func setActiveController(_ controller: IMAPIdleController) {
        activeController = controller
    }

    private func clearActiveController() {
        activeController = nil
    }

    private func markStopped() {
        isRunning = false
    }
}
