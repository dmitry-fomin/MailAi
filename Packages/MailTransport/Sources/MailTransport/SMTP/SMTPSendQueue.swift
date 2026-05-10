import Foundation
import Core

// MARK: - SMTPSendQueue

/// Очередь отправки SMTP-писем с retry и exponential backoff.
///
/// Особенности:
/// - In-memory очередь (персистентность в SQLite — post-MVP).
/// - Retry до `maxRetries` попыток с задержкой `baseDelay * 2^attempt`.
/// - Максимальная задержка — `maxRetryDelay` (30s).
/// - Только одна отправка одновременно (serial dispatch), чтобы не перегружать сервер.
/// - Статусы задания: `queued` → `sending` → `sent` / `failed`.
/// - Наблюдение за статусами через `AsyncStream`.
///
/// Retryable ошибки: `SMTPError.connection`, `SMTPError.tls`,
/// `SMTPError.relay` с кодами 421 / 450 / 451 / 452.
/// Все остальные ошибки — permanent (не retry).
public actor SMTPSendQueue {

    // MARK: - Nested types

    /// Уникальный идентификатор задания в очереди.
    public typealias JobID = UUID

    /// Статус задания отправки.
    public enum JobStatus: Sendable, Equatable {
        /// Задание ожидает отправки.
        case queued
        /// Задание активно отправляется (попытка `attempt` из `maxRetries`).
        case sending(attempt: Int)
        /// Письмо успешно отправлено.
        case sent
        /// Все попытки исчерпаны или permanent-ошибка.
        case failed(reason: String)
    }

    /// Задание в очереди отправки.
    public struct Job: Sendable, Identifiable {
        public let id: JobID
        public let envelope: Envelope
        public let body: MIMEBody
        public var status: JobStatus
        /// Количество выполненных попыток.
        public var attempts: Int
        /// Дата постановки в очередь.
        public let enqueuedAt: Date

        init(envelope: Envelope, body: MIMEBody) {
            self.id = UUID()
            self.envelope = envelope
            self.body = body
            self.status = .queued
            self.attempts = 0
            self.enqueuedAt = Date()
        }
    }

    // MARK: - Configuration

    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public static let maxRetryDelay: TimeInterval = 30.0

    // MARK: - State

    /// Все задания (включая выполненные и упавшие — для отображения в UI).
    private var jobs: [JobID: Job] = [:]
    /// Порядок заданий в очереди.
    private var pendingIDs: [JobID] = []
    /// Наблюдатели за изменениями.
    private var continuations: [UUID: AsyncStream<[Job]>.Continuation] = [:]

    // MARK: - Init

    public init(maxRetries: Int = 3, baseDelay: TimeInterval = 2.0) {
        precondition(maxRetries >= 0 && baseDelay > 0)
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
    }

    // MARK: - Public API

    /// Добавляет задание в очередь. Возвращает идентификатор задания.
    @discardableResult
    public func enqueue(envelope: Envelope, body: MIMEBody) -> JobID {
        let job = Job(envelope: envelope, body: body)
        jobs[job.id] = job
        pendingIDs.append(job.id)
        broadcast()
        return job.id
    }

    /// Возвращает текущий статус задания.
    public func status(for jobID: JobID) -> JobStatus? {
        jobs[jobID]?.status
    }

    /// Снапшот всех заданий (для UI/тестов).
    public func allJobs() -> [Job] {
        jobs.values.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    /// Подписывается на изменения списка заданий.
    /// Атомарная регистрация — без race condition.
    public func observe() -> AsyncStream<[Job]> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(self.allJobs())
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    /// Удаляет выполненные/упавшие задания из истории.
    public func clearCompleted() {
        let completedIDs = jobs.filter {
            if case .sent = $0.value.status { return true }
            if case .failed = $0.value.status { return true }
            return false
        }.map(\.key)
        for id in completedIDs { jobs.removeValue(forKey: id) }
        broadcast()
    }

    // MARK: - Processing

    /// Запускает обработку очереди с указанным провайдером.
    /// Возвращается когда очередь пуста. Для постоянного фонового
    /// процессинга вызывайте в цикле или используйте `processForever`.
    public func processAll(provider: any SendProvider) async {
        while !pendingIDs.isEmpty {
            guard !Task.isCancelled else { break }
            guard let jobID = pendingIDs.first else { break }

            await processJob(id: jobID, provider: provider)
        }
    }

    /// Непрерывный фоновый процессинг. Засыпает когда очередь пуста.
    /// Отменяется через Task cancellation.
    public func processForever(provider: any SendProvider) async {
        while !Task.isCancelled {
            if pendingIDs.isEmpty {
                // Ждём появления новых заданий (короткий poll)
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                continue
            }
            await processAll(provider: provider)
        }
    }

    // MARK: - Private processing

    private func processJob(id: JobID, provider: any SendProvider) async {
        guard var job = jobs[id] else { return }

        // Помечаем как отправляемое
        job.status = .sending(attempt: job.attempts + 1)
        jobs[id] = job
        pendingIDs.removeAll { $0 == id }
        broadcast()

        do {
            try await provider.send(envelope: job.envelope, body: job.body)
            // Успех
            job.status = .sent
            job.attempts += 1
            jobs[id] = job
            broadcast()
        } catch {
            job.attempts += 1
            if shouldRetry(error: error, attempts: job.attempts) {
                // Retryable — возвращаем в очередь с задержкой
                let delay = retryDelay(attempt: job.attempts)
                job.status = .queued
                jobs[id] = job
                // Добавляем в конец очереди
                pendingIDs.append(id)
                broadcast()

                // Ожидаем перед следующей попыткой
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                // Permanent failure
                job.status = .failed(reason: error.localizedDescription)
                jobs[id] = job
                broadcast()
            }
        }
    }

    // MARK: - Retry logic

    /// Вычисляет задержку перед следующей попыткой.
    /// Формула: `baseDelay * 2^(attempt-1)`, макс. `maxRetryDelay`.
    public func retryDelay(attempt: Int) -> TimeInterval {
        let delay = baseDelay * pow(2.0, Double(max(0, attempt - 1)))
        return min(delay, Self.maxRetryDelay)
    }

    /// Определяет, нужна ли повторная попытка для данной ошибки.
    /// Retryable: ошибки сети, transient SMTP (4xx), TLS.
    /// Permanent: auth failures, relay errors, permanent SMTP (5xx).
    private func shouldRetry(error: any Error, attempts: Int) -> Bool {
        guard attempts < maxRetries else { return false }

        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .connection:
                // Сетевая ошибка — retryable
                return true
            case .tls:
                // TLS ошибка — retryable (транзиентная)
                return true
            case .relay(let code, _):
                // RFC 5321: 4xx = transient negative (retryable), 5xx = permanent
                return code >= 421 && code < 500
            case .channelClosed:
                // Канал закрыт — retryable (сетевая проблема)
                return true
            case .authenticationFailed, .authMethodNotSupported, .authentication:
                // Ошибки аутентификации — permanent (пароль не изменится)
                return false
            case .unexpectedResponse, .unexpectedCode:
                // Неожиданный ответ — permanent
                return false
            }
        }

        // Для неизвестных ошибок (URLError и т.п.) — retryable
        return true
    }

    // MARK: - Observation helpers

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast() {
        let snapshot = allJobs()
        for cont in continuations.values {
            cont.yield(snapshot)
        }
    }
}
