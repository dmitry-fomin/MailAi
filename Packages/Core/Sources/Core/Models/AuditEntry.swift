import Foundation

/// Запись в `classification_log`. По инвариантам приватности содержит
/// **только** техническую телеметрию — ни subject, ни from, ни тела.
/// `messageIdHash` — SHA-256 от `message.messageID` (не сам ID).
public struct AuditEntry: Sendable, Hashable, Codable {
    public let id: UUID
    public let messageIdHash: String
    public let model: String
    public let tokensIn: Int
    public let tokensOut: Int
    public let durationMs: Int
    public let confidence: Double
    public let matchedRuleId: UUID?
    public let errorCode: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        messageIdHash: String,
        model: String,
        tokensIn: Int,
        tokensOut: Int,
        durationMs: Int,
        confidence: Double,
        matchedRuleId: UUID? = nil,
        errorCode: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.messageIdHash = messageIdHash
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.durationMs = durationMs
        self.confidence = confidence
        self.matchedRuleId = matchedRuleId
        self.errorCode = errorCode
        self.createdAt = createdAt
    }
}
