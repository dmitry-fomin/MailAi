import Foundation
import Core

/// Парсер SOAP-ответов от Exchange Web Services.
/// Использует `XMLParser` (Foundation) — без внешних зависимостей.
public enum EWSResponseParser {

    // MARK: - Autodiscover

    public static func parseAutodiscoverEWSURL(from data: Data) -> URL? {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        // Autodiscover возвращает несколько <Protocol>: EXCH (внутренний) и EXPR (внешний).
        // Предпочитаем EXPR (External RPC over HTTP) — он доступен снаружи корпоративной сети.
        // Если EXPR нет — fallback на первый попавшийся EwsUrl.
        let protocols = parser.collectElements(named: "Protocol")
        // Сначала ищем EXPR
        for proto in protocols {
            guard proto.child(named: "Type")?.text == "EXPR" else { continue }
            if let urlStr = proto.child(named: "EwsUrl")?.text ?? proto.child(named: "ASUrl")?.text,
               let url = URL(string: urlStr) {
                return url
            }
        }
        // Fallback: первый EwsUrl
        for proto in protocols {
            if let urlStr = proto.child(named: "EwsUrl")?.text ?? proto.child(named: "ASUrl")?.text,
               let url = URL(string: urlStr) {
                return url
            }
        }
        return nil
    }

    // MARK: - GetFolder / FindFolder

    public static func parseFolders(from data: Data) throws -> [EWSFolder] {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        try checkFault(parser: parser)
        return parser.collectElements(named: "Folder").compactMap(parseFolder)
    }

    public static func parseFindFolders(from data: Data) throws -> [EWSFolder] {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        try checkFault(parser: parser)
        return parser.collectElements(named: "Folder").compactMap(parseFolder)
    }

    private static func parseFolder(_ el: XMLElement) -> EWSFolder? {
        guard let folderIdEl = el.child(named: "FolderId"),
              let id = folderIdEl.attributes["Id"],
              let ck = folderIdEl.attributes["ChangeKey"] else { return nil }
        let name = el.child(named: "DisplayName")?.text ?? ""
        let total = Int(el.child(named: "TotalCount")?.text ?? "0") ?? 0
        let unread = Int(el.child(named: "UnreadCount")?.text ?? "0") ?? 0
        let childCount = Int(el.child(named: "ChildFolderCount")?.text ?? "0") ?? 0
        return EWSFolder(
            id: id, changeKey: ck, displayName: name,
            totalCount: total, unreadCount: unread, childFolderCount: childCount
        )
    }

    // MARK: - FindItem

    public static func parseFindItems(from data: Data) throws -> EWSFindItemResult {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        try checkFault(parser: parser)

        let totalCount = parser.firstAttribute(named: "TotalItemsInView").flatMap(Int.init) ?? 0
        let items = parser.collectElements(named: "Message").compactMap(parseItem)
        return EWSFindItemResult(items: items, totalCount: totalCount)
    }

    /// Один экземпляр на весь парсер — ISO8601DateFormatter создание дорогостоящее.
    /// nonisolated(unsafe): ISO8601DateFormatter не Sendable, но используется
    /// только для чтения (форматирование дат) — мутации состояния нет.
    nonisolated(unsafe) private static let iso8601DateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func parseItem(_ el: XMLElement) -> EWSItem? {
        guard let itemIdEl = el.child(named: "ItemId"),
              let id = itemIdEl.attributes["Id"],
              let ck = itemIdEl.attributes["ChangeKey"] else { return nil }

        let internetMsgID = el.child(named: "InternetMessageId")?.text
        let subject = el.child(named: "Subject")?.text ?? "(без темы)"
        let from = parseMailbox(el.child(named: "From")?.child(named: "Mailbox"))
        let toRecipients = parseRecipientList(el.child(named: "ToRecipients"))
        let ccRecipients = parseRecipientList(el.child(named: "CcRecipients"))
        let dateStr = el.child(named: "DateTimeReceived")?.text ?? ""
        let date = iso8601DateFormatter.date(from: dateStr) ?? Date.distantPast
        let size = Int(el.child(named: "Size")?.text ?? "0") ?? 0
        let isRead = el.child(named: "IsRead")?.text?.lowercased() == "true"
        let hasAttach = el.child(named: "HasAttachments")?.text?.lowercased() == "true"
        let importance = el.child(named: "Importance")?.text ?? "Normal"

        return EWSItem(
            id: id, changeKey: ck,
            internetMessageID: internetMsgID,
            subject: subject,
            from: from,
            toRecipients: toRecipients,
            ccRecipients: ccRecipients,
            dateReceived: date,
            size: size,
            isRead: isRead,
            hasAttachments: hasAttach,
            importance: importance,
            listUnsubscribeHeader: nil
        )
    }

    private static func parseMailbox(_ el: XMLElement?) -> (name: String?, address: String)? {
        guard let el, let addr = el.child(named: "EmailAddress")?.text else { return nil }
        let name = el.child(named: "Name")?.text
        return (name: name, address: addr)
    }

    private static func parseRecipientList(_ el: XMLElement?) -> [(name: String?, address: String)] {
        guard let el else { return [] }
        return el.children
            .filter { $0.name == "Mailbox" }
            .compactMap { parseMailbox($0) }
    }

    // MARK: - GetItem MIME

    public static func parseMIMEContent(from data: Data) throws -> Data {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        try checkFault(parser: parser)
        guard let base64 = parser.firstText(forElementNamed: "MimeContent") else {
            throw MailError.parsing("MimeContent не найден в ответе GetItem")
        }
        guard let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw MailError.parsing("Не удалось декодировать MimeContent из base64")
        }
        return decoded
    }

    // MARK: - Generic error check

    public static func checkNoError(data: Data, operation: String) throws {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        try checkFault(parser: parser)
    }

    private static func checkFault(parser: SimpleXMLParser) throws {
        // Проверяем Fault (HTTP 500 / SOAP fault)
        if let fault = parser.firstText(forElementNamed: "faultstring") {
            throw MailError.protocolViolation("EWS SOAP fault: \(fault)")
        }
        // Проверяем EWS-level error в каждом ResponseMessage-элементе по отдельности.
        // firstAttribute(named:) ищет первый атрибут во всём дереве — при батч-ответах
        // пропускает ошибки в не-первых сообщениях. Проверяем все response messages.
        let responseMessages = parser.collectElements(named: "ResponseCode")
            .compactMap { $0 }  // просто для получения доступа к родителю через контекст
        // Поскольку SimpleXMLParser не хранит ссылки на родителей, проверяем
        // все элементы с атрибутом ResponseClass напрямую через индекс атрибутов.
        // Для надёжного батч-контроля обходим все ResponseMessage-узлы.
        let messageNames = [
            "GetFolderResponseMessage", "FindFolderResponseMessage",
            "FindItemResponseMessage", "GetItemResponseMessage",
            "DeleteItemResponseMessage", "MoveItemResponseMessage",
            "UpdateItemResponseMessage"
        ]
        for msgName in messageNames {
            for msgEl in parser.collectElements(named: msgName) {
                guard let rc = msgEl.attributes["ResponseClass"] else { continue }
                if rc == "Error" {
                    let code = msgEl.child(named: "ResponseCode")?.text ?? "Unknown"
                    let msg = msgEl.child(named: "MessageText")?.text ?? ""
                    if code == "ErrorAccessDenied" || code == "ErrorInvalidCredentials" {
                        throw MailError.authentication(.invalidCredentials)
                    }
                    throw MailError.protocolViolation("EWS \(code): \(msg)")
                }
            }
        }
        // Fallback: если ни один из конкретных типов не нашёлся — проверяем
        // хотя бы первый встреченный ResponseClass в дереве.
        _ = responseMessages  // использован выше через parser
        if let responseClass = parser.firstAttribute(named: "ResponseClass"),
           responseClass == "Error" {
            let code = parser.firstText(forElementNamed: "ResponseCode") ?? "Unknown"
            let msg = parser.firstText(forElementNamed: "MessageText") ?? ""
            if code == "ErrorAccessDenied" || code == "ErrorInvalidCredentials" {
                throw MailError.authentication(.invalidCredentials)
            }
            throw MailError.protocolViolation("EWS \(code): \(msg)")
        }
    }
}

// MARK: - Simple SAX → DOM

/// Лёгкий XML-парсер поверх `XMLParser`.
/// Строит дерево только в памяти в рамках одного запроса; тела писем сюда не попадают.
final class SimpleXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var stack: [XMLElement] = []
    private(set) var root: XMLElement?

    // Кеши для быстрого поиска по имени/атрибуту (заполняются post-parse)
    private var elementsByName: [String: [XMLElement]] = [:]
    private var firstAttributes: [String: String] = [:]

    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }

    func parse() {
        parser.parse()
        // Строим индексы
        if let root { indexElement(root) }
    }

    private func indexElement(_ el: XMLElement) {
        elementsByName[el.name, default: []].append(el)
        for (k, v) in el.attributes { firstAttributes[k] = firstAttributes[k] ?? v }
        for child in el.children { indexElement(child) }
    }

    func collectElements(named name: String) -> [XMLElement] {
        elementsByName[name] ?? []
    }

    func firstText(forElementNamed name: String) -> String? {
        elementsByName[name]?.first?.text
    }

    func firstAttribute(named name: String) -> String? {
        firstAttributes[name]
    }

    func firstText(forPath path: [String]) -> String? {
        guard let first = path.first else { return nil }
        guard let el = elementsByName[first]?.first else { return nil }
        if path.count == 1 { return el.text }
        return findText(in: el, remainingPath: Array(path.dropFirst()))
    }

    private func findText(in el: XMLElement, remainingPath: [String]) -> String? {
        guard let first = remainingPath.first else { return el.text }
        for child in el.children where child.name == first {
            if let result = findText(in: child, remainingPath: Array(remainingPath.dropFirst())) {
                return result
            }
        }
        return nil
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let el = XMLElement(name: localName(elementName), attributes: attributes)
        stack.last?.children.append(el)
        stack.append(el)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            stack.last?.text = (stack.last?.text ?? "") + trimmed
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        let el = stack.removeLast()
        if stack.isEmpty { root = el }
    }

    private func localName(_ qname: String) -> String {
        // Strip namespace prefix (e.g. "t:Subject" → "Subject", "m:GetFolder" → "GetFolder")
        if let colon = qname.firstIndex(of: ":") {
            return String(qname[qname.index(after: colon)...])
        }
        return qname
    }
}

final class XMLElement {
    let name: String
    var attributes: [String: String]
    var text: String?
    var children: [XMLElement] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(named n: String) -> XMLElement? {
        children.first(where: { $0.name == n })
    }
}
