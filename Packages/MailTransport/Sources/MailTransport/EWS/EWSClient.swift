import Foundation
import Core

/// HTTP-клиент для Exchange Web Services (EWS) SOAP API.
/// Авторизация — HTTP Basic. Один экземпляр на аккаунт; поточно-безопасен.
public actor EWSClient {
    public let ewsURL: URL
    private let session: URLSession
    private let credentials: String  // base64(user:pass)

    public init(ewsURL: URL, username: String, password: String) {
        self.ewsURL = ewsURL
        let raw = "\(username):\(password)"
        self.credentials = Data(raw.utf8).base64EncodedString()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Core request

    func send(body: String) async throws -> Data {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
                       xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
                       xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header>
            <t:RequestServerVersion Version="Exchange2010_SP2"/>
          </soap:Header>
          <soap:Body>
        \(body)
          </soap:Body>
        </soap:Envelope>
        """
        var request = URLRequest(url: ewsURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MailError.network(.unknown)
        }
        switch http.statusCode {
        case 200...299: return data
        case 401: throw MailError.authentication(.invalidCredentials)
        case 500:
            // Exchange returns HTTP 500 for SOAP faults — return data so caller can parse fault
            return data
        case 0..<200, 300...: throw MailError.network(.serverRejected)
        default: throw MailError.network(.unknown)
        }
    }

    // MARK: - GetFolder

    public func getFolders(ids: [EWSDistinguishedFolderID]) async throws -> [EWSFolder] {
        let folderIds = ids.map {
            "<t:DistinguishedFolderId Id=\"\($0.rawValue)\"/>"
        }.joined(separator: "\n")

        let soapBody = """
            <m:GetFolder>
              <m:FolderShape>
                <t:BaseShape>Default</t:BaseShape>
              </m:FolderShape>
              <m:FolderIds>
        \(folderIds)
              </m:FolderIds>
            </m:GetFolder>
        """
        let data = try await send(body: soapBody)
        return try EWSResponseParser.parseFolders(from: data)
    }

    public func findSubfolders(parentID: String) async throws -> [EWSFolder] {
        let soapBody = """
            <m:FindFolder Traversal="Shallow">
              <m:FolderShape>
                <t:BaseShape>Default</t:BaseShape>
              </m:FolderShape>
              <m:ParentFolderIds>
                <t:FolderId Id="\(xmlEscape(parentID))"/>
              </m:ParentFolderIds>
            </m:FindFolder>
        """
        let data = try await send(body: soapBody)
        return try EWSResponseParser.parseFindFolders(from: data)
    }

    // MARK: - FindItem (list messages)

    public func findItems(
        folderID: String,
        offset: Int,
        maxCount: Int
    ) async throws -> EWSFindItemResult {
        let soapBody = """
            <m:FindItem Traversal="Shallow">
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
                  <t:FieldURI FieldURI="message:InternetMessageId"/>
                  <t:FieldURI FieldURI="item:Subject"/>
                  <t:FieldURI FieldURI="message:From"/>
                  <t:FieldURI FieldURI="message:ToRecipients"/>
                  <t:FieldURI FieldURI="message:CcRecipients"/>
                  <t:FieldURI FieldURI="item:DateTimeReceived"/>
                  <t:FieldURI FieldURI="item:Size"/>
                  <t:FieldURI FieldURI="message:IsRead"/>
                  <t:FieldURI FieldURI="item:HasAttachments"/>
                  <t:FieldURI FieldURI="item:Importance"/>
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:IndexedPageItemView MaxEntriesReturned="\(maxCount)" Offset="\(offset)" BasePoint="Beginning"/>
              <m:SortOrder>
                <t:FieldOrder Order="Descending">
                  <t:FieldURI FieldURI="item:DateTimeReceived"/>
                </t:FieldOrder>
              </m:SortOrder>
              <m:ParentFolderIds>
                <t:FolderId Id="\(xmlEscape(folderID))"/>
              </m:ParentFolderIds>
            </m:FindItem>
        """
        let data = try await send(body: soapBody)
        return try EWSResponseParser.parseFindItems(from: data)
    }

    // MARK: - GetItem (body)

    public func getItemMIME(itemID: String, changeKey: String) async throws -> Data {
        let soapBody = """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:IncludeMimeContent>true</t:IncludeMimeContent>
              </m:ItemShape>
              <m:ItemIds>
                <t:ItemId Id="\(xmlEscape(itemID))" ChangeKey="\(xmlEscape(changeKey))"/>
              </m:ItemIds>
            </m:GetItem>
        """
        let data = try await send(body: soapBody)
        return try EWSResponseParser.parseMIMEContent(from: data)
    }

    // MARK: - DeleteItem

    public func deleteItem(itemID: String, changeKey: String, moveToDeletedItems: Bool = true) async throws {
        let deleteType = moveToDeletedItems ? "MoveToDeletedItems" : "HardDelete"
        let soapBody = """
            <m:DeleteItem DeleteType="\(deleteType)" SendMeetingCancellations="SendToNone">
              <m:ItemIds>
                <t:ItemId Id="\(xmlEscape(itemID))" ChangeKey="\(xmlEscape(changeKey))"/>
              </m:ItemIds>
            </m:DeleteItem>
        """
        let data = try await send(body: soapBody)
        try EWSResponseParser.checkNoError(data: data, operation: "DeleteItem")
    }

    // MARK: - MoveItem

    public func moveItem(itemID: String, changeKey: String, toFolderID: String) async throws {
        let soapBody = """
            <m:MoveItem>
              <m:ToFolderId>
                <t:FolderId Id="\(xmlEscape(toFolderID))"/>
              </m:ToFolderId>
              <m:ItemIds>
                <t:ItemId Id="\(xmlEscape(itemID))" ChangeKey="\(xmlEscape(changeKey))"/>
              </m:ItemIds>
            </m:MoveItem>
        """
        let data = try await send(body: soapBody)
        try EWSResponseParser.checkNoError(data: data, operation: "MoveItem")
    }

    // MARK: - UpdateItem (flags)

    public func setReadFlag(_ isRead: Bool, itemID: String, changeKey: String) async throws {
        let value = isRead ? "true" : "false"
        let soapBody = """
            <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AutoResolve">
              <m:ItemChanges>
                <t:ItemChange>
                  <t:ItemId Id="\(xmlEscape(itemID))" ChangeKey="\(xmlEscape(changeKey))"/>
                  <t:Updates>
                    <t:SetItemField>
                      <t:FieldURI FieldURI="message:IsRead"/>
                      <t:Message>
                        <t:IsRead>\(value)</t:IsRead>
                      </t:Message>
                    </t:SetItemField>
                  </t:Updates>
                </t:ItemChange>
              </m:ItemChanges>
            </m:UpdateItem>
        """
        let data = try await send(body: soapBody)
        try EWSResponseParser.checkNoError(data: data, operation: "UpdateItem")
    }

    public func setFlaggedFlag(_ isFlagged: Bool, itemID: String, changeKey: String) async throws {
        let flagStatus = isFlagged ? "Flagged" : "NotFlagged"
        let soapBody = """
            <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AutoResolve">
              <m:ItemChanges>
                <t:ItemChange>
                  <t:ItemId Id="\(xmlEscape(itemID))" ChangeKey="\(xmlEscape(changeKey))"/>
                  <t:Updates>
                    <t:SetItemField>
                      <t:FieldURI FieldURI="item:Flag"/>
                      <t:Message>
                        <t:Flag>
                          <t:FlagStatus>\(flagStatus)</t:FlagStatus>
                        </t:Flag>
                      </t:Message>
                    </t:SetItemField>
                  </t:Updates>
                </t:ItemChange>
              </m:ItemChanges>
            </m:UpdateItem>
        """
        let data = try await send(body: soapBody)
        try EWSResponseParser.checkNoError(data: data, operation: "UpdateItem")
    }

    // MARK: - Autodiscover

    public static func autodiscover(email: String, password: String) async throws -> URL {
        let domain = String(email.split(separator: "@").last ?? "")
        let candidates = [
            "https://autodiscover.\(domain)/autodiscover/autodiscover.xml",
            "https://\(domain)/autodiscover/autodiscover.xml"
        ]
        let credentials = Data("\(email):\(password)".utf8).base64EncodedString()
        let requestBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006">
          <Request>
            <EMailAddress>\(email)</EMailAddress>
            <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
          </Request>
        </Autodiscover>
        """
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data(requestBody.utf8)
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if let ewsURL = EWSResponseParser.parseAutodiscoverEWSURL(from: data) {
                return ewsURL
            }
        }
        throw MailError.network(.serverRejected)
    }
}

// MARK: - Supporting types

public enum EWSDistinguishedFolderID: String {
    case inbox = "inbox"
    case sentitems = "sentitems"
    case drafts = "drafts"
    case deleteditems = "deleteditems"
    case junkemail = "junkemail"
    case archive = "archivemsgfolderroot"
    case msgfolderroot = "msgfolderroot"
}

public struct EWSFolder: Sendable {
    public let id: String
    public let changeKey: String
    public let displayName: String
    public let totalCount: Int
    public let unreadCount: Int
    public let childFolderCount: Int
}

public struct EWSItem: Sendable {
    public let id: String
    public let changeKey: String
    public let internetMessageID: String?
    public let subject: String
    public let from: (name: String?, address: String)?
    public let toRecipients: [(name: String?, address: String)]
    public let ccRecipients: [(name: String?, address: String)]
    public let dateReceived: Date
    public let size: Int
    public let isRead: Bool
    public let hasAttachments: Bool
    public let importance: String
    public let listUnsubscribeHeader: String?  // nil в FindItem, заполняется через GetItem
}

public struct EWSFindItemResult: Sendable {
    public let items: [EWSItem]
    public let totalCount: Int
}

// MARK: - Helpers

private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}
