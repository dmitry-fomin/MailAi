import Foundation
import CryptoKit
import Core
import Storage
import AI

/// Координирует классификацию: достаёт сообщения из `Storage`, запрашивает
/// snippet через `bodyFetcher`, вызывает `Classifier`, пишет результат в
/// `Storage.messages.importance` + `ClassificationLog`.
///
/// Строгие инварианты приватности:
/// - В `bodyFetcher` передаётся `Message.ID`, тело извлекается строго 150-char snippet'ом.
/// - В лог не пишутся subject/from/to/snippet — только `SHA-256(message_id)`.
/// - После записи snippet высвобождается (уходит из scope).
public actor ClassificationCoordinator {
    public let store: GRDBMetadataStore
    public let rules: RuleEngine
    public let classifier: Classifier
    public let log: ClassificationLog
    public let queue: ClassificationQueue
    public let bodyFetcher: @Sendable (Message.ID) async throws -> (body: String, contentType: String)

    public init(
        store: GRDBMetadataStore,
        rules: RuleEngine,
        classifier: Classifier,
        log: ClassificationLog,
        queue: ClassificationQueue,
        bodyFetcher: @escaping @Sendable (Message.ID) async throws -> (body: String, contentType: String)
    ) {
        self.store = store
        self.rules = rules
        self.classifier = classifier
        self.log = log
        self.queue = queue
        self.bodyFetcher = bodyFetcher
    }

    public func enqueue(messageIDs: [Message.ID]) async {
        await queue.enqueue(messageIDs.map(\.rawValue))
    }

    /// Прогоняет всю очередь. Возвращается, когда очередь опустошена.
    public func runUntilDrained() async {
        let store = self.store
        let classifier = self.classifier
        let rules = self.rules
        let log = self.log
        let bodyFetcher = self.bodyFetcher

        await queue.processAll { rawID in
            let id = Message.ID(rawID)
            guard let msg = try await store.message(id: id) else { return }
            let (body, contentType) = try await bodyFetcher(id)
            let snippet = SnippetExtractor.extract(body: body, contentType: contentType)
            let active = try await rules.activeRules()

            let input = ClassificationInput(
                from: msg.from?.address ?? "",
                to: msg.to.map(\.address),
                subject: msg.subject,
                date: msg.date,
                listUnsubscribe: false,  // TODO: когда будет парсинг headers, пробросить
                contentType: contentType,
                bodySnippet: snippet,
                activeRules: active
            )

            var errorCode: String?
            var result: ClassificationResult?
            do {
                result = try await classifier.classify(input: input)
            } catch let e as ClassifierError {
                errorCode = Self.code(for: e)
            } catch let e as OpenRouterError {
                errorCode = Self.code(for: e)
            } catch {
                errorCode = "unknown"
            }

            if let result {
                try await store.updateImportance(messageID: id, to: result.importance)
            }

            let hash = Self.sha256(msg.messageID ?? msg.id.rawValue)
            try await log.append(AuditEntry(
                messageIdHash: hash,
                model: classifier.model,
                tokensIn: result?.tokensIn ?? 0,
                tokensOut: result?.tokensOut ?? 0,
                durationMs: result?.durationMs ?? 0,
                confidence: result?.confidence ?? 0,
                matchedRuleId: result?.matchedRule,
                errorCode: errorCode
            ))

            if errorCode != nil { throw ClassificationCoordinatorError.classifyFailed }
        }
    }

    // MARK: - Helpers

    private static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func code(for error: ClassifierError) -> String {
        switch error {
        case .emptyResponse: return "empty"
        case .malformedJSON: return "malformed_json"
        }
    }

    private static func code(for error: OpenRouterError) -> String {
        switch error {
        case .invalidResponse: return "invalid_response"
        case .unauthorized: return "401"
        case .paymentRequired: return "402"
        case .rateLimited: return "429"
        case .serverError(let s): return "5xx_\(s)"
        case .httpError(let s): return "http_\(s)"
        }
    }
}

public enum ClassificationCoordinatorError: Error, Sendable {
    case classifyFailed
}
