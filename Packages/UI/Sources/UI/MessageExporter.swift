import AppKit
import Foundation
import Core

// MARK: - MessageExporter

/// Экспортирует письма в форматы `.eml` (RFC 2822) и `.mbox` (Unix mailbox).
///
/// Форматы:
/// - `.eml` — одно письмо, отдельный файл. Стандарт: RFC 2822.
/// - `.mbox` — несколько писем в одном файле. Стандарт: mboxrd (RFC 4155).
///
/// Экспортируются только метаданные из `Message` (заголовки) + тело из `MessageBody`.
/// Тело никогда не сохраняется в SQLite или логах.
///
/// Использует `NSSavePanel` / `NSOpenPanel` для выбора пути.
@MainActor
public final class MessageExporter {

    public static let shared = MessageExporter()

    private init() {}

    // MARK: - Export Single .eml

    /// Экспортирует одно письмо в `.eml` через `NSSavePanel`.
    ///
    /// - Parameters:
    ///   - message: Метаданные письма.
    ///   - body: Тело письма (только в памяти).
    ///   - window: Родительское окно для sheet-модала. `nil` — открывает отдельный диалог.
    public func exportEML(
        message: Message,
        body: MessageBody?,
        in window: NSWindow? = nil
    ) async {
        let filename = sanitizeFilename(message.subject.isEmpty ? "message" : message.subject) + ".eml"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.init(filenameExtension: "eml") ?? .emailMessage]
        panel.canCreateDirectories = true
        panel.message = "Экспортировать письмо как .eml"

        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }

        guard response == .OK, let url = panel.url else { return }

        let emlData = buildEML(message: message, body: body)
        try? emlData.write(to: url)
    }

    // MARK: - Export Multiple .mbox

    /// Экспортирует несколько писем в один `.mbox` через `NSSavePanel`.
    ///
    /// - Parameters:
    ///   - messages: Список (метаданные, тело) пар. Тела могут быть `nil`.
    ///   - suggestedName: Предложенное имя файла (без расширения).
    ///   - window: Родительское окно для sheet-модала.
    ///   - progressHandler: Вызывается с (текущий индекс, всего) во время записи.
    public func exportMbox(
        messages: [(message: Message, body: MessageBody?)],
        suggestedName: String = "mailbox",
        in window: NSWindow? = nil,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async {
        guard !messages.isEmpty else { return }

        let filename = sanitizeFilename(suggestedName) + ".mbox"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.init(filenameExtension: "mbox") ?? .data]
        panel.canCreateDirectories = true
        panel.message = "Экспортировать \(messages.count) писем в .mbox"

        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }

        guard response == .OK, let url = panel.url else { return }

        // Строим mbox в памяти (потоковая запись для больших объёмов — будущая оптимизация).
        var mboxData = Data()
        for (index, pair) in messages.enumerated() {
            progressHandler?(index + 1, messages.count)
            let emlData = buildMboxEntry(message: pair.message, body: pair.body)
            mboxData.append(emlData)
        }

        try? mboxData.write(to: url)
    }

    // MARK: - Export to Directory (.eml files)

    /// Экспортирует несколько писем как отдельные `.eml` файлы в выбранную папку.
    ///
    /// - Parameters:
    ///   - messages: Список (метаданные, тело) пар.
    ///   - window: Родительское окно для sheet-модала.
    ///   - progressHandler: Вызывается с (текущий индекс, всего) во время записи.
    public func exportEMLFiles(
        messages: [(message: Message, body: MessageBody?)],
        in window: NSWindow? = nil,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async {
        guard !messages.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку для сохранения \(messages.count) писем (.eml)"
        panel.prompt = "Экспортировать"

        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }

        guard response == .OK, let directoryURL = panel.url else { return }

        for (index, pair) in messages.enumerated() {
            progressHandler?(index + 1, messages.count)
            let rawName = pair.message.subject.isEmpty ? "message-\(index + 1)" : pair.message.subject
            let filename = sanitizeFilename(rawName) + ".eml"
            let fileURL = directoryURL.appendingPathComponent(filename)
            let emlData = buildEML(message: pair.message, body: pair.body)
            try? emlData.write(to: fileURL)
        }
    }

    // MARK: - EML Builder (RFC 2822)

    /// Строит RFC 2822 `.eml` содержимое.
    func buildEML(message: Message, body: MessageBody?) -> Data {
        var lines: [String] = []

        // Headers
        lines.append("MIME-Version: 1.0")
        lines.append("Message-ID: <\(message.id)>")
        lines.append("Date: \(rfc2822Date(message.date))")

        if let from = message.from {
            lines.append("From: \(formatAddress(from))")
        }

        if !message.to.isEmpty {
            lines.append("To: \(message.to.map { formatAddress($0) }.joined(separator: ", "))")
        }

        if !message.cc.isEmpty {
            lines.append("Cc: \(message.cc.map { formatAddress($0) }.joined(separator: ", "))")
        }

        let subject = message.subject.isEmpty ? "(Без темы)" : message.subject
        lines.append("Subject: \(encodeHeader(subject))")

        // Content headers
        if let body {
            switch body.content {
            case .html:
                lines.append("Content-Type: text/html; charset=UTF-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
            case .plain:
                lines.append("Content-Type: text/plain; charset=UTF-8")
                lines.append("Content-Transfer-Encoding: quoted-printable")
            }
        } else {
            lines.append("Content-Type: text/plain; charset=UTF-8")
        }

        // Empty line separating headers from body
        lines.append("")

        // Body
        if let body {
            switch body.content {
            case .html(let html): lines.append(html)
            case .plain(let text): lines.append(text)
            }
        } else {
            lines.append("(Тело письма недоступно)")
        }

        let text = lines.joined(separator: "\r\n")
        return text.data(using: .utf8) ?? Data()
    }

    // MARK: - mbox Entry Builder (mboxrd, RFC 4155)

    /// Строит одну запись mbox (From_ line + EML).
    ///
    /// Формат mboxrd: каждая запись начинается со строки `From <addr> <date>`,
    /// внутри тела строки `From ` экранируются символом `>`.
    private func buildMboxEntry(message: Message, body: MessageBody?) -> Data {
        let fromAddress = message.from?.address ?? "unknown"
        let dateString = mboxDate(message.date)
        let fromLine = "From \(fromAddress) \(dateString)\r\n"

        let emlData = buildEML(message: message, body: body)

        // mboxrd: экранируем строки ^"From " в теле
        var emlString = String(data: emlData, encoding: .utf8) ?? ""
        emlString = emlString.replacingOccurrences(
            of: "\nFrom ",
            with: "\n>From ",
            options: .literal
        )

        // Разделитель между записями — пустая строка
        let entry = fromLine + emlString + "\r\n"
        return entry.data(using: .utf8) ?? Data()
    }

    // MARK: - Helpers

    private func formatAddress(_ address: MailAddress) -> String {
        if let name = address.name, !name.isEmpty {
            // RFC 2822 quoted string для имени если содержит спецсимволы
            let needsQuoting = name.contains(",") || name.contains("@") || name.contains("(") || name.contains(")")
            let displayName = needsQuoting ? "\"\(name)\"" : name
            return "\(displayName) <\(address.address)>"
        }
        return address.address
    }

    private func rfc2822Date(_ date: Date) -> String {
        // RFC 2822: "Wed, 01 Jan 2025 12:00:00 +0300"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    private func mboxDate(_ date: Date) -> String {
        // mbox From_ line date: "Wed Jan  1 12:00:00 2025"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private func encodeHeader(_ value: String) -> String {
        // Если содержит только ASCII — без кодирования.
        if value.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            return value
        }
        // RFC 2047 UTF-8 Base64 encoding: =?UTF-8?B?...?=
        let encoded = Data(value.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: invalid).joined(separator: "_")
        return sanitized.prefix(200).description // macOS limit
    }
}
