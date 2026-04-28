import Foundation
import Core
import MailTransport

/// Разбирает сырые RFC822-байты из IMAP FETCH в типизированный `MessageBody`.
/// Использует `MIMEStreamParser` для построчного разбора без накопления всего
/// тела в памяти. Предпочитает HTML-часть, если найдена; иначе — plain text.
enum MIMEBodyParser {

    static func parse(bytes: [UInt8], messageID: Message.ID) -> MessageBody {
        let collector = Collector(messageID: messageID)
        let parser = MIMEStreamParser { event in collector.handle(event) }
        parser.feed(bytes)
        parser.finish()

        let content: MessageBody.Content
        if let html = collector.htmlBody {
            content = .html(html)
        } else if let plain = collector.plainBody {
            content = .plain(plain)
        } else {
            content = .plain(String(bytes: bytes, encoding: .utf8) ?? "")
        }
        return MessageBody(messageID: messageID, content: content, attachments: collector.attachments)
    }

    // MARK: - Collector

    private final class Collector {
        struct PartBuf {
            var headers: [MIMEHeader] = []
            var bytes: [UInt8] = []
        }

        var bufs: [String: PartBuf] = [:]
        var htmlBody: String?
        var plainBody: String?
        var attachments: [Attachment] = []
        let messageID: Message.ID

        init(messageID: Message.ID) { self.messageID = messageID }

        func handle(_ event: MIMEStreamEvent) {
            switch event {
            case .partStart(let path, let headers):
                let key = pathKey(path)
                bufs[key, default: .init()].headers = headers
            case .bodyChunk(let path, let bytes):
                let key = pathKey(path)
                bufs[key, default: .init()].bytes.append(contentsOf: bytes)
            case .partEnd(let path):
                let key = pathKey(path)
                guard let buf = bufs.removeValue(forKey: key) else { return }
                finalize(path: path, key: key, buf: buf)
            }
        }

        private func pathKey(_ path: [Int]) -> String {
            path.isEmpty ? "root" : path.map(String.init).joined(separator: ".")
        }

        private func finalize(path: [Int], key: String, buf: PartBuf) {
            let ctFull = Self.headerValue("content-type", in: buf.headers)
            let ct = ctFull.components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""

            guard !ct.hasPrefix("multipart/") else { return }

            let dispFull = Self.headerValue("content-disposition", in: buf.headers)
            let disp = dispFull.components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""

            let isExplicitAttachment = disp == "attachment"
            let isInline = disp == "inline"
            let hasFilename = Self.filenameParam(from: buf.headers) != nil
            let isNonText = !ct.isEmpty && !ct.hasPrefix("text/")

            let shouldBeAttachment: Bool
            if path.isEmpty {
                shouldBeAttachment = isExplicitAttachment
            } else {
                shouldBeAttachment = isExplicitAttachment || hasFilename || isNonText
            }

            if shouldBeAttachment {
                let mimeType = ct.isEmpty ? "application/octet-stream" : ct
                let filename = Self.filenameParam(from: buf.headers) ?? "attachment"
                let partNum = path.isEmpty ? nil : path.map { String($0 + 1) }.joined(separator: ".")
                attachments.append(Attachment(
                    id: .init("\(messageID.rawValue)-\(key)"),
                    messageID: messageID,
                    filename: filename,
                    mimeType: mimeType,
                    size: buf.bytes.count,
                    partNumber: partNum,
                    isInline: isInline
                ))
            } else if ct.hasPrefix("text/html") && htmlBody == nil {
                htmlBody = String(bytes: buf.bytes, encoding: .utf8)
                        ?? String(bytes: buf.bytes, encoding: .isoLatin1)
                        ?? ""
            } else if (ct.hasPrefix("text/plain") || ct.isEmpty) && plainBody == nil {
                plainBody = String(bytes: buf.bytes, encoding: .utf8)
                         ?? String(bytes: buf.bytes, encoding: .isoLatin1)
                         ?? ""
            }
        }

        // MARK: - Header helpers

        private static func headerValue(_ name: String, in headers: [MIMEHeader]) -> String {
            headers.first(where: { $0.name.lowercased() == name })?.value ?? ""
        }

        private static func filenameParam(from headers: [MIMEHeader]) -> String? {
            for header in headers {
                let n = header.name.lowercased()
                guard n == "content-disposition" || n == "content-type" else { continue }
                if n == "content-disposition" {
                    if let v = paramValue("filename*", in: header.value) {
                        return rfc5987Decode(v)
                    }
                    if let v = paramValue("filename", in: header.value) { return v }
                }
                if n == "content-type" {
                    if let v = paramValue("name", in: header.value) { return v }
                }
            }
            return nil
        }

        private static func paramValue(_ param: String, in headerValue: String) -> String? {
            for part in headerValue.components(separatedBy: ";").dropFirst() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let eq = trimmed.firstIndex(of: "=") else { continue }
                let pName = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                guard pName == param else { continue }
                let val = String(trimmed[trimmed.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return val
            }
            return nil
        }

        private static func rfc5987Decode(_ value: String) -> String {
            // Format: charset'language'encoded — strip prefix, percent-decode
            let parts = value.components(separatedBy: "'")
            guard parts.count >= 3 else { return value }
            return parts[2].removingPercentEncoding ?? parts[2]
        }
    }
}
