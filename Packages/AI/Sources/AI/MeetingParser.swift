import Foundation
import Core
import Storage

// MARK: - Public Types

/// Предложение встречи, извлечённое AI из письма.
public struct MeetingProposal: Sendable, Equatable {
    public let title: String
    public let startDate: Date
    public let endDate: Date?
    public let location: String?
    /// Адреса участников.
    public let attendees: [String]
    /// Дополнительные заметки (agenda, dial-in).
    public let notes: String?
    /// Уверенность AI (0.0 – 1.0).
    public let confidence: Double

    public init(
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        location: String? = nil,
        attendees: [String] = [],
        notes: String? = nil,
        confidence: Double
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.attendees = attendees
        self.notes = notes.flatMap { $0.isEmpty ? nil : $0 }
        self.confidence = max(0, min(1, confidence))
    }
}

// MARK: - Protocol

/// Абстракция парсера встреч. Позволяет мокировать в тестах.
public protocol AIMeetingExtractor: Actor {
    /// Анализирует текст письма и извлекает данные встречи.
    ///
    /// Вызывается ТОЛЬКО по явному клику пользователя — не автоматически.
    ///
    /// - Parameters:
    ///   - subject: Тема письма.
    ///   - bodySnippet: Фрагмент тела письма (до 1000 символов).
    ///   - messageID: ID письма — для кеширования.
    /// - Returns: `MeetingProposal` если встреча обнаружена, `nil` если нет.
    func extractMeeting(
        subject: String,
        bodySnippet: String,
        messageID: Message.ID
    ) async throws -> MeetingProposal?
}

// MARK: - Implementation

/// Актор-парсер встреч через OpenRouter.
///
/// Анализирует тему и сниппет письма (до 1000 символов), извлекает:
/// дату/время, место, участников. Результат кешируется в AIResultCache.
///
/// Пороговое значение уверенности: >= 0.7 — показывать баннер в ReaderView.
///
/// Приватность:
/// - Передаётся только snippet (не полное тело).
/// - Вызов ТОЛЬКО по клику пользователя.
/// - Кеширование по SHA-256(messageID) в ai_cache.
public actor MeetingParser: AIMeetingExtractor {
    public let provider: any AIProvider
    public let cache: AIResultCache
    /// Порог уверенности для отображения результата в UI.
    public static let confidenceThreshold = 0.7

    public init(provider: any AIProvider, cache: AIResultCache) {
        self.provider = provider
        self.cache = cache
    }

    public func extractMeeting(
        subject: String,
        bodySnippet: String,
        messageID: Message.ID
    ) async throws -> MeetingProposal? {
        // Проверяем кеш
        if let cached = try? await cachedProposal(for: messageID.rawValue) {
            return cached
        }

        let userPrompt = buildUserPrompt(subject: subject, bodySnippet: bodySnippet)

        var buffer = ""
        for try await chunk in provider.complete(
            system: Self.systemPrompt,
            user: userPrompt,
            streaming: false,
            maxTokens: 400
        ) {
            buffer += chunk
        }

        guard !buffer.isEmpty else { return nil }

        let proposal = parseProposal(buffer)

        // Кешируем результат (даже nil — чтобы не повторять запрос)
        try? await cacheProposal(proposal, for: messageID.rawValue)

        return proposal
    }

    // MARK: - Private

    private func buildUserPrompt(subject: String, bodySnippet: String) -> String {
        let snippet = String(bodySnippet.prefix(1_000))
        return "Subject: \(subject)\n\nBody:\n\(snippet)"
    }

    private func parseProposal(_ text: String) -> MeetingProposal? {
        // Проверяем явный null-ответ
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "null" || trimmed == "{}" { return nil }

        let json = Classifier.extractJSONObject(text)
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MeetingResponse.self, from: data),
              !decoded.isNull
        else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Пробуем несколько форматов даты
        func parseDate(_ str: String?) -> Date? {
            guard let str, !str.isEmpty else { return nil }
            if let d = iso.date(from: str) { return d }
            // Fallback: без долей секунд
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            return iso2.date(from: str)
        }

        guard let startDate = parseDate(decoded.startDate) else { return nil }

        return MeetingProposal(
            title: decoded.title,
            startDate: startDate,
            endDate: parseDate(decoded.endDate),
            location: decoded.location.flatMap { $0.isEmpty ? nil : $0 },
            attendees: decoded.attendees ?? [],
            notes: decoded.notes,
            confidence: decoded.confidence
        )
    }

    // MARK: - Wire Types

    private struct MeetingResponse: Decodable {
        let title: String
        let startDate: String?
        let endDate: String?
        let location: String?
        let attendees: [String]?
        let notes: String?
        let confidence: Double
        /// Флаг, что письмо не содержит встречи.
        var isNull: Bool { startDate == nil || startDate?.isEmpty == true || title.isEmpty }

        enum CodingKeys: String, CodingKey {
            case title, location, attendees, notes, confidence
            case startDate = "startDate"
            case endDate = "endDate"
        }
    }

    // MARK: - System Prompt

    private static let systemPrompt = """
        You are a meeting extractor. Analyze the email and extract meeting details.

        If the email contains a meeting, call, event, or appointment:
        Return JSON:
        {
          "title": "meeting title",
          "startDate": "ISO8601 datetime with timezone",
          "endDate": "ISO8601 datetime or null",
          "location": "physical location, URL, or null",
          "attendees": ["email1", "email2"],
          "notes": "agenda or dial-in info or null",
          "confidence": 0.0-1.0
        }

        If no meeting is found, return:
        {"title": "", "startDate": null, "endDate": null, "location": null, "attendees": [], "notes": null, "confidence": 0.0}

        High confidence (>0.8): explicit date+time mentioned.
        Medium confidence (0.5-0.8): date mentioned but time unclear.
        Low confidence (<0.5): vague reference to meeting.
        """
}

// MARK: - MeetingParser Cache helpers
// AIResultCache хранит meeting JSON через generic feature-key API.
// Методы meetingProposalJSON / storeMeetingJSON определены в Storage:
// Packages/Storage/Sources/Storage/AIResultCache+MeetingParser.swift

extension MeetingParser {
    private static let nullSentinel = "__null__"

    func cachedProposal(for messageID: String) async throws -> MeetingProposal? {
        guard let json = try await cache.meetingJSON(for: messageID) else { return nil }
        if json == Self.nullSentinel { return nil }
        return decodeProposal(json)
    }

    func cacheProposal(_ proposal: MeetingProposal?, for messageID: String) async throws {
        if let proposal {
            if let data = try? JSONEncoder().encode(CachedMeeting(proposal)),
               let json = String(data: data, encoding: .utf8) {
                try await cache.storeMeetingJSON(json, for: messageID)
            }
        } else {
            try await cache.storeMeetingJSON(Self.nullSentinel, for: messageID)
        }
    }

    private func decodeProposal(_ json: String) -> MeetingProposal? {
        guard let data = json.data(using: .utf8),
              let cached = try? JSONDecoder().decode(CachedMeeting.self, from: data)
        else { return nil }
        return MeetingProposal(
            title: cached.title,
            startDate: cached.startDate,
            endDate: cached.endDate,
            location: cached.location,
            attendees: cached.attendees,
            notes: cached.notes,
            confidence: cached.confidence
        )
    }

    private struct CachedMeeting: Codable {
        let title: String
        let startDate: Date
        let endDate: Date?
        let location: String?
        let attendees: [String]
        let notes: String?
        let confidence: Double

        init(_ p: MeetingProposal) {
            title = p.title; startDate = p.startDate; endDate = p.endDate
            location = p.location; attendees = p.attendees; notes = p.notes; confidence = p.confidence
        }
    }
}
