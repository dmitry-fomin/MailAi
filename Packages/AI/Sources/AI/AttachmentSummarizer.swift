import Foundation
import Core

// MARK: - Public Types

/// Входные данные для суммаризации вложения.
/// Текст уже извлечён вызывающим кодом (PDFKit, NSAttributedString, etc.).
/// Тело файла не сохраняется на диск — только в памяти на время запроса.
public struct AttachmentSummaryInput: Sendable {
    /// Имя файла (для контекста промпта).
    public let filename: String
    /// MIME-тип вложения.
    public let mimeType: String
    /// Текстовые чанки документа (разбиты по 4000 символов с перекрытием 200).
    public let textChunks: [String]
    /// Общее число символов в документе.
    public let totalChars: Int

    public init(filename: String, mimeType: String, textChunks: [String], totalChars: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.textChunks = textChunks
        self.totalChars = totalChars
    }
}

/// Результат суммаризации вложения.
public struct AttachmentSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let summary: String
    public let keyPoints: [String]
    /// Число страниц (если доступно из PDFDocument).
    public let pageCount: Int?
    public let tokensIn: Int
    public let tokensOut: Int

    public init(
        id: UUID = UUID(),
        summary: String,
        keyPoints: [String],
        pageCount: Int? = nil,
        tokensIn: Int = 0,
        tokensOut: Int = 0
    ) {
        self.id = id
        self.summary = summary
        self.keyPoints = keyPoints
        self.pageCount = pageCount
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
    }
}

// MARK: - Protocol

/// Абстракция суммаризатора вложений. Позволяет мокировать в тестах.
public protocol AIAttachmentSummarizer: Actor {
    /// Суммаризирует вложение по переданному тексту.
    /// Вызывается ТОЛЬКО по явному клику пользователя.
    /// - Parameters:
    ///   - input: Извлечённые текстовые чанки вложения.
    ///   - pageCount: Число страниц (для PDF, опционально).
    func summarize(input: AttachmentSummaryInput, pageCount: Int?) async throws -> AttachmentSummary
}

// MARK: - Implementation

/// Актор суммаризации вложений через OpenRouter.
///
/// Поддерживаемые форматы (извлечение текста — на стороне вызывающего кода):
/// - PDF: PDFKit
/// - DOCX: ZIP → word/document.xml → NSAttributedString
/// - TXT/RTF: прямо как String
///
/// Стратегия Map-Reduce для больших файлов:
/// - <= 8000 символов: один AI-запрос.
/// - > 8000 символов: суммаризировать каждый чанк → суммаризировать суммаризации.
/// - Максимум 3 уровня reduce.
///
/// Приватность:
/// - Текст вложения передаётся в AI ТОЛЬКО по явному клику.
/// - Не кешируется (вложения не уникальны по ID в общем случае).
/// - Не сохраняется на диск.
public actor AttachmentSummarizer: AIAttachmentSummarizer {
    public let provider: any AIProvider
    /// Максимум символов для прямого запроса без Map-Reduce.
    public static let singlePassThreshold = 8_000
    /// Размер чанка при Map-Reduce.
    public static let chunkSize = 4_000
    /// Максимальное число уровней reduce.
    public static let maxReduceLevels = 3

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    public func summarize(
        input: AttachmentSummaryInput,
        pageCount: Int? = nil
    ) async throws -> AttachmentSummary {
        let started = Date()
        var tokensIn = 0
        var tokensOut = 0

        let finalSummary: (summary: String, keyPoints: [String])

        if input.totalChars <= Self.singlePassThreshold || input.textChunks.count <= 1 {
            // Прямой запрос
            let fullText = input.textChunks.joined(separator: "\n")
            let (system, user) = buildPrompt(filename: input.filename, text: fullText)
            tokensIn += Classifier.estimateTokens(system) + Classifier.estimateTokens(user)

            var buffer = ""
            for try await chunk in provider.complete(
                system: system,
                user: user,
                streaming: false,
                maxTokens: 512
            ) {
                buffer += chunk
            }
            tokensOut += Classifier.estimateTokens(buffer)
            finalSummary = parseResponse(buffer)
        } else {
            // Map-Reduce
            let result = try await mapReduce(
                chunks: input.textChunks,
                filename: input.filename,
                tokensIn: &tokensIn,
                tokensOut: &tokensOut,
                level: 0
            )
            finalSummary = result
        }

        let duration = Int(Date().timeIntervalSince(started) * 1000)
        _ = duration

        return AttachmentSummary(
            summary: finalSummary.summary,
            keyPoints: finalSummary.keyPoints,
            pageCount: pageCount,
            tokensIn: tokensIn,
            tokensOut: tokensOut
        )
    }

    // MARK: - Map-Reduce

    private func mapReduce(
        chunks: [String],
        filename: String,
        tokensIn: inout Int,
        tokensOut: inout Int,
        level: Int
    ) async throws -> (summary: String, keyPoints: [String]) {
        // Map: суммаризируем каждый чанк
        var chunkSummaries: [String] = []
        for chunk in chunks {
            let (system, user) = buildPrompt(filename: filename, text: chunk)
            tokensIn += Classifier.estimateTokens(system) + Classifier.estimateTokens(user)

            var buffer = ""
            for try await part in provider.complete(
                system: system,
                user: user,
                streaming: false,
                maxTokens: 300
            ) {
                buffer += part
            }
            tokensOut += Classifier.estimateTokens(buffer)
            let parsed = parseResponse(buffer)
            chunkSummaries.append(parsed.summary)
        }

        // Reduce: объединяем суммаризации
        let combined = chunkSummaries.joined(separator: "\n\n")

        // Если ещё большой — рекурсивно (до maxReduceLevels)
        if combined.count > Self.singlePassThreshold && level < Self.maxReduceLevels {
            let subChunks = stride(from: 0, to: combined.count, by: Self.chunkSize).map { start -> String in
                let from = combined.index(combined.startIndex, offsetBy: start)
                let to = combined.index(from, offsetBy: min(Self.chunkSize, combined.count - start))
                return String(combined[from..<to])
            }
            return try await mapReduce(
                chunks: subChunks,
                filename: filename,
                tokensIn: &tokensIn,
                tokensOut: &tokensOut,
                level: level + 1
            )
        }

        // Финальный reduce
        let (system, user) = buildReducePrompt(filename: filename, summaries: chunkSummaries)
        tokensIn += Classifier.estimateTokens(system) + Classifier.estimateTokens(user)

        var finalBuffer = ""
        for try await part in provider.complete(
            system: system,
            user: user,
            streaming: false,
            maxTokens: 512
        ) {
            finalBuffer += part
        }
        tokensOut += Classifier.estimateTokens(finalBuffer)
        return parseResponse(finalBuffer)
    }

    // MARK: - Prompt Builders

    private func buildPrompt(filename: String, text: String) -> (system: String, user: String) {
        let system = """
            Summarize the document content. Return JSON:
            {"summary": "3-5 sentences describing the document", "keyPoints": ["key point 1", "key point 2", ...up to 5]}
            """
        let user = "Filename: \(filename)\n\nContent:\n\(text)"
        return (system, user)
    }

    private func buildReducePrompt(filename: String, summaries: [String]) -> (system: String, user: String) {
        let system = """
            Combine these partial summaries into a final document summary. Return JSON:
            {"summary": "3-5 sentences overall summary", "keyPoints": ["key point 1", ...up to 5]}
            """
        let numbered = summaries.enumerated().map { "Part \($0.offset + 1): \($0.element)" }.joined(separator: "\n\n")
        let user = "Filename: \(filename)\n\nPartial summaries:\n\(numbered)"
        return (system, user)
    }

    // MARK: - Parsing

    private func parseResponse(_ text: String) -> (summary: String, keyPoints: [String]) {
        let json = Classifier.extractJSONObject(text)
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SummaryResponse.self, from: data)
        else {
            // Возвращаем сырой текст как summary если JSON не распознан
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        return (decoded.summary, decoded.keyPoints)
    }

    private struct SummaryResponse: Decodable {
        let summary: String
        let keyPoints: [String]

        enum CodingKeys: String, CodingKey {
            case summary
            case keyPoints = "keyPoints"
        }
    }
}

// MARK: - Text Extraction Helpers

/// Вспомогательные методы для извлечения текста из вложений.
/// Вызываются в UI-слое перед передачей в AttachmentSummarizer.
public enum AttachmentTextExtractor {
    /// Поддерживаемые MIME-типы для суммаризации.
    public static func canSummarize(mimeType: String) -> Bool {
        let lower = mimeType.lowercased()
        return lower.contains("pdf")
            || lower.contains("text/")
            || lower.contains("rtf")
            || lower.contains("word")
            || lower.contains("msword")
            || lower.contains("openxmlformats-officedocument.wordprocessingml")
    }

    /// Разбивает текст на чанки с перекрытием.
    /// chunkSize: символов в чанке, overlap: символов перекрытия.
    public static func makeChunks(
        text: String,
        chunkSize: Int = AttachmentSummarizer.chunkSize,
        overlap: Int = 200
    ) -> [String] {
        guard text.count > chunkSize else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: min(chunkSize, text.distance(from: start, to: text.endIndex)))
            chunks.append(String(text[start..<end]))
            // Сдвигаемся вперёд на chunkSize - overlap
            let advance = max(1, chunkSize - overlap)
            guard let next = text.index(start, offsetBy: advance, limitedBy: text.endIndex) else { break }
            start = next
        }
        return chunks
    }

    /// Собирает AttachmentSummaryInput из уже извлечённого текста.
    public static func makeInput(filename: String, mimeType: String, text: String) -> AttachmentSummaryInput {
        let chunks = makeChunks(text: text)
        return AttachmentSummaryInput(
            filename: filename,
            mimeType: mimeType,
            textChunks: chunks,
            totalChars: text.count
        )
    }
}
