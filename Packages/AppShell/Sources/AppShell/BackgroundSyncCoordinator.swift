import Foundation
import Core
import MailTransport

// MARK: - SyncProgress

/// Снапшот прогресса синхронизации одного аккаунта.
public struct SyncProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Ожидание следующего тика polling'а. Следующий запуск — через `nextSyncIn`.
        case idle
        /// Идёт полная загрузка папок/сообщений.
        case syncing
        /// Синхронизация завершилась успешно. Время последнего успешного sync.
        case completed(at: Date)
        /// Последний sync завершился ошибкой.
        case failed(message: String)
    }

    public let accountID: Account.ID
    public let phase: Phase
    /// Время до следующего polling-тика. nil — когда phase != .idle.
    public let nextSyncIn: Duration?

    public init(accountID: Account.ID, phase: Phase, nextSyncIn: Duration? = nil) {
        self.accountID = accountID
        self.phase = phase
        self.nextSyncIn = nextSyncIn
    }
}

// MARK: - SyncCoordinatorDelegate

/// Делегат, который координатор вызывает при получении IDLE-события или
/// при наступлении polling-тика. Реализуется на стороне `AccountSessionModel`
/// или другого владельца данных.
public protocol SyncCoordinatorDelegate: AnyObject, Sendable {
    /// Вызывается, когда нужно обновить список писем для указанного аккаунта.
    /// Реализация должна быть быстрой (не блокирующей): запускает Task внутри.
    func syncDidRequestRefresh(for accountID: Account.ID) async
}

// MARK: - BackgroundSyncCoordinator

/// Актор, управляющий фоновой синхронизацией одного аккаунта.
///
/// Запускает два независимых канала обновления:
/// 1. **Polling** — периодический тик каждые `interval` секунд (fallback/дополнение к IDLE).
/// 2. **IDLE-нотификации** — подписывается на `AsyncStream<IMAPIdleEvent>` и при событиях
///    `.exists` / `.expunge` немедленно запрашивает обновление у делегата.
///
/// Публикует `AsyncStream<SyncProgress>` для наблюдения из UI.
///
/// Жизненный цикл: `start()` → работает → `stop()`.
/// Повторный `start()` после `stop()` не поддерживается; создайте новый экземпляр.
public actor BackgroundSyncCoordinator {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Интервал polling-тиков. Default: 5 минут.
        public let pollingInterval: Duration
        /// Если `true` — polling продолжается даже при наличии IDLE-стрима.
        /// Используется как двойная страховка.
        public let pollingAlwaysActive: Bool

        public init(
            pollingInterval: Duration = .seconds(5 * 60),
            pollingAlwaysActive: Bool = true
        ) {
            self.pollingInterval = pollingInterval
            self.pollingAlwaysActive = pollingAlwaysActive
        }

        public static let `default` = Configuration()
    }

    // MARK: - Public state

    public private(set) var isRunning = false

    // MARK: - Progress stream

    /// Публичный стрим снапшотов прогресса. Один подписчик за раз.
    public nonisolated var progress: AsyncStream<SyncProgress> { _progress }

    // MARK: - Private

    private let accountID: Account.ID
    private let configuration: Configuration
    private weak var delegate: (any SyncCoordinatorDelegate)?

    private let _progress: AsyncStream<SyncProgress>
    private let progressContinuation: AsyncStream<SyncProgress>.Continuation

    private var pollingTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        accountID: Account.ID,
        configuration: Configuration = .default,
        delegate: any SyncCoordinatorDelegate
    ) {
        self.accountID = accountID
        self.configuration = configuration
        self.delegate = delegate

        let (stream, cont) = AsyncStream<SyncProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self._progress = stream
        self.progressContinuation = cont
    }

    deinit {
        progressContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Запускает polling и, опционально, подписку на IDLE-события.
    ///
    /// - Parameter idleEvents: стрим событий от `IMAPIdleController.events`.
    ///   Если `nil` — работает только polling.
    public func start(idleEvents: AsyncStream<IMAPIdleEvent>? = nil) {
        guard !isRunning else { return }
        isRunning = true

        publishProgress(.idle, nextSyncIn: configuration.pollingInterval)

        startPolling()
        if let events = idleEvents {
            startIDLEListener(events: events)
        }
    }

    /// Останавливает все фоновые задачи. Стрим `progress` завершается.
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        pollingTask?.cancel()
        idleTask?.cancel()
        pollingTask = nil
        idleTask = nil

        progressContinuation.finish()
    }

    /// Немедленно инициирует внеплановый sync (например, по pull-to-refresh).
    public func triggerManualSync() async {
        await performSync()
    }

    // MARK: - Polling

    private func startPolling() {
        let interval = configuration.pollingInterval
        let accountID = self.accountID

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                // Ждём интервал, потом синхронизируем.
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break // CancellationError
                }
                guard !Task.isCancelled else { break }
                await self?.performSync()
            }
            // Финальный idle-прогресс не публикуем — stop() завершает стрим.
            _ = accountID // suppress unused warning
        }
    }

    // MARK: - IDLE listener

    private func startIDLEListener(events: AsyncStream<IMAPIdleEvent>) {
        idleTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handleIDLEEvent(event)
            }
        }
    }

    private func handleIDLEEvent(_ event: IMAPIdleEvent) async {
        switch event {
        case .exists, .expunge:
            // Сервер сообщил об изменениях — запрашиваем обновление немедленно.
            await performSync()

        case .idleStarted, .idleStopped, .other:
            // Технические события — без действий.
            break
        }
    }

    // MARK: - Sync

    private func performSync() async {
        guard isRunning else { return }
        publishProgress(.syncing)

        do {
            guard let delegate else {
                publishProgress(.failed(message: "Делегат освобождён"), nextSyncIn: configuration.pollingInterval)
                return
            }
            await delegate.syncDidRequestRefresh(for: accountID)
            publishProgress(.completed(at: Date()), nextSyncIn: configuration.pollingInterval)
            // После завершения — публикуем idle с таймером до следующего тика.
            publishProgress(.idle, nextSyncIn: configuration.pollingInterval)
        }
    }

    // MARK: - Progress helpers

    private func publishProgress(_ phase: SyncProgress.Phase, nextSyncIn: Duration? = nil) {
        let snap = SyncProgress(
            accountID: accountID,
            phase: phase,
            nextSyncIn: phase == .idle ? nextSyncIn : nil
        )
        progressContinuation.yield(snap)
    }
}
