import Foundation
import Core
import Secrets

// MARK: - GraphMailError

public enum GraphMailError: Error, Sendable {
    /// HTTP-ошибка от Graph API.
    case httpError(statusCode: Int, body: String)
    /// Ошибка парсинга JSON-ответа.
    case parseError(String)
    /// Не удалось получить access_token.
    case authError(String)
    /// Сетевая ошибка.
    case networkError(String)
    /// Операция не поддерживается.
    case unsupported(String)
}

// MARK: - GraphPageResult

/// Страница результатов Graph API (поддерживает delta sync через deltaLink).
public struct GraphPageResult<T: Sendable>: Sendable {
    public let items: [T]
    /// Следующая страница (если есть).
    public let nextLink: URL?
    /// Delta link для инкрементальной синхронизации (delta query).
    public let deltaLink: URL?

    public init(items: [T], nextLink: URL?, deltaLink: URL?) {
        self.items = items
        self.nextLink = nextLink
        self.deltaLink = deltaLink
    }
}

// MARK: - GraphMessage

/// Сообщение из Microsoft Graph API (упрощённая модель).
public struct GraphMessage: Sendable, Identifiable {
    public let id: String
    public let subject: String
    public let from: MailAddress?
    public let toRecipients: [MailAddress]
    public let receivedDateTime: Date
    public let isRead: Bool
    public let hasAttachments: Bool
    public let bodyPreview: String
    public let internetMessageId: String?
    public let conversationId: String?

    public init(
        id: String,
        subject: String,
        from: MailAddress?,
        toRecipients: [MailAddress],
        receivedDateTime: Date,
        isRead: Bool,
        hasAttachments: Bool,
        bodyPreview: String,
        internetMessageId: String?,
        conversationId: String?
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.toRecipients = toRecipients
        self.receivedDateTime = receivedDateTime
        self.isRead = isRead
        self.hasAttachments = hasAttachments
        self.bodyPreview = bodyPreview
        self.internetMessageId = internetMessageId
        self.conversationId = conversationId
    }
}

// MARK: - GraphMailFolder

/// Папка из Microsoft Graph API.
public struct GraphMailFolder: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let totalItemCount: Int
    public let unreadItemCount: Int
    public let parentFolderId: String?

    public init(
        id: String,
        displayName: String,
        totalItemCount: Int,
        unreadItemCount: Int,
        parentFolderId: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.totalItemCount = totalItemCount
        self.unreadItemCount = unreadItemCount
        self.parentFolderId = parentFolderId
    }
}

// MARK: - GraphMailClient

/// HTTP-клиент для Microsoft Graph Mail API v1.0.
///
/// Endpoint: `https://graph.microsoft.com/v1.0/me/`
///
/// Поддерживает:
/// - Список писем (`messages`) с фильтрацией и пагинацией.
/// - Чтение тела письма (`messages/<id>`).
/// - Перемещение (`messages/<id>/move`).
/// - Удаление (`messages/<id>`).
/// - Отправку (`sendMail`).
/// - Список папок (`mailFolders`).
/// - Delta sync через `messages/delta` для инкрементальных обновлений.
///
/// Авторизация: OAuth2 Bearer token через `OAuthTokenManager`.
/// Токен автоматически обновляется при истечении.
///
/// Безопасность: access_token никогда не логируется.
public actor GraphMailClient {

    private static let baseURL = URL(string: "https://graph.microsoft.com/v1.0/me/")!

    private let accountID: Account.ID
    private let tokenManager: OAuthTokenManager
    private let urlSession: URLSession

    // MARK: - Init

    public init(
        accountID: Account.ID,
        tokenManager: OAuthTokenManager,
        urlSession: URLSession? = nil
    ) {
        self.accountID = accountID
        self.tokenManager = tokenManager
        if let session = urlSession {
            self.urlSession = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            self.urlSession = URLSession(configuration: config)
        }
    }

    // MARK: - Messages: List

    /// Возвращает страницу писем из указанной папки.
    ///
    /// - Parameters:
    ///   - folderID: ID папки (`inbox`, `sentitems`, или Graph folder ID). По умолчанию — inbox.
    ///   - top: Количество писем на странице (макс. 1000).
    ///   - select: Поля для возврата (для экономии трафика).
    ///   - filter: OData-фильтр (например `isRead eq false`).
    ///   - orderby: Сортировка (например `receivedDateTime desc`).
    public func listMessages(
        inFolder folderID: String = "inbox",
        top: Int = 50,
        select: [String] = GraphMailClient.defaultMessageSelect,
        filter: String? = nil,
        orderby: String = "receivedDateTime desc"
    ) async throws -> GraphPageResult<GraphMessage> {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("mailFolders/\(folderID)/messages"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "$top", value: String(top)),
            URLQueryItem(name: "$select", value: select.joined(separator: ",")),
            URLQueryItem(name: "$orderby", value: orderby)
        ]
        if let filter { queryItems.append(URLQueryItem(name: "$filter", value: filter)) }
        components.queryItems = queryItems

        let data = try await get(url: components.url!)
        return try parseMessagesPage(data: data)
    }

    /// Загружает следующую страницу по `nextLink` (пагинация).
    public func nextPage(link: URL) async throws -> GraphPageResult<GraphMessage> {
        let data = try await get(url: link)
        return try parseMessagesPage(data: data)
    }

    // MARK: - Messages: Delta Sync

    /// Возвращает изменения с момента последней синхронизации.
    ///
    /// - Parameter deltaLink: Delta link из предыдущего ответа. `nil` — начальная синхронизация.
    /// - Returns: Изменённые письма + новый deltaLink для следующего вызова.
    ///
    /// Используйте `deltaLink` из результата для следующего вызова — это позволяет
    /// загружать только изменения, а не все письма.
    public func deltaMessages(
        inFolder folderID: String = "inbox",
        deltaLink: URL? = nil,
        select: [String] = GraphMailClient.defaultMessageSelect
    ) async throws -> GraphPageResult<GraphMessage> {
        let url: URL
        if let link = deltaLink {
            url = link
        } else {
            var components = URLComponents(
                url: Self.baseURL.appendingPathComponent("mailFolders/\(folderID)/messages/delta"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "$select", value: select.joined(separator: ","))
            ]
            url = components.url!
        }
        let data = try await get(url: url)
        return try parseMessagesPage(data: data)
    }

    // MARK: - Messages: Read

    /// Загружает полное письмо включая HTML-тело.
    /// Тело НЕ хранится на диск — только в памяти в рамках вызова.
    public func getMessage(id: String) async throws -> (message: GraphMessage, htmlBody: String?) {
        let url = Self.baseURL
            .appendingPathComponent("messages/\(id)")
            .appending(queryItems: [
                URLQueryItem(name: "$select", value: (GraphMailClient.defaultMessageSelect + ["body"]).joined(separator: ","))
            ])
        let data = try await get(url: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GraphMailError.parseError("Не удалось разобрать JSON письма")
        }
        let message = try parseMessage(json: json)

        var htmlBody: String?
        if let bodyObj = json["body"] as? [String: Any],
           let content = bodyObj["content"] as? String {
            htmlBody = content
        }
        return (message, htmlBody)
    }

    // MARK: - Messages: Move

    /// Перемещает письмо в другую папку.
    public func moveMessage(id: String, toFolder destinationFolderID: String) async throws {
        let url = Self.baseURL.appendingPathComponent("messages/\(id)/move")
        let body = ["destinationId": destinationFolderID]
        _ = try await post(url: url, body: body)
    }

    // MARK: - Messages: Delete

    /// Удаляет письмо (перемещает в Deleted Items).
    public func deleteMessage(id: String) async throws {
        let url = Self.baseURL.appendingPathComponent("messages/\(id)")
        try await delete(url: url)
    }

    /// Удаляет несколько писем. Выполняется последовательно.
    public func deleteMessages(ids: [String]) async throws {
        for id in ids {
            try await deleteMessage(id: id)
        }
    }

    // MARK: - Messages: Send

    /// Отправляет письмо через Graph API `sendMail`.
    ///
    /// - Parameters:
    ///   - subject: Тема письма.
    ///   - htmlBody: HTML-тело письма.
    ///   - to: Адреса получателей.
    ///   - cc: Cc-получатели.
    ///   - bcc: Bcc-получатели.
    ///   - saveToSentItems: Сохранять ли в Отправленные. По умолчанию `true`.
    ///
    /// Примечание: тело письма не логируется и не сохраняется на диск.
    public func sendMail(
        subject: String,
        htmlBody: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        saveToSentItems: Bool = true
    ) async throws {
        let url = Self.baseURL.appendingPathComponent("sendMail")

        func recipients(_ addresses: [String]) -> [[String: Any]] {
            addresses.map { addr -> [String: Any] in
                ["emailAddress": ["address": addr]]
            }
        }

        let message: [String: Any] = [
            "subject": subject,
            "body": ["contentType": "HTML", "content": htmlBody],
            "toRecipients": recipients(to),
            "ccRecipients": recipients(cc),
            "bccRecipients": recipients(bcc)
        ]

        let payload: [String: Any] = [
            "message": message,
            "saveToSentItems": saveToSentItems
        ]

        _ = try await post(url: url, body: payload)
    }

    // MARK: - Mail Folders

    /// Возвращает список папок верхнего уровня.
    public func listFolders() async throws -> [GraphMailFolder] {
        let url = Self.baseURL
            .appendingPathComponent("mailFolders")
            .appending(queryItems: [
                URLQueryItem(name: "$top", value: "100"),
                URLQueryItem(name: "$select", value: "id,displayName,totalItemCount,unreadItemCount,parentFolderId")
            ])
        let data = try await get(url: url)

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = json["value"] as? [[String: Any]]
        else {
            throw GraphMailError.parseError("Не удалось разобрать список папок")
        }

        return value.compactMap { parseFolderJSON($0) }
    }

    /// Возвращает вложенные папки.
    public func listChildFolders(parentID: String) async throws -> [GraphMailFolder] {
        let url = Self.baseURL
            .appendingPathComponent("mailFolders/\(parentID)/childFolders")
            .appending(queryItems: [
                URLQueryItem(name: "$select", value: "id,displayName,totalItemCount,unreadItemCount,parentFolderId")
            ])
        let data = try await get(url: url)

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = json["value"] as? [[String: Any]]
        else {
            throw GraphMailError.parseError("Не удалось разобрать вложенные папки")
        }

        return value.compactMap { parseFolderJSON($0) }
    }

    // MARK: - Mark as read/unread

    /// Отмечает письмо как прочитанное или непрочитанное.
    public func markRead(id: String, isRead: Bool) async throws {
        let url = Self.baseURL.appendingPathComponent("messages/\(id)")
        _ = try await patch(url: url, body: ["isRead": isRead])
    }

    // MARK: - HTTP helpers

    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await setAuthHeader(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await execute(request: request)
    }

    private func post(url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        try await setAuthHeader(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(request: request)
    }

    private func patch(url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        try await setAuthHeader(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(request: request)
    }

    private func delete(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try await setAuthHeader(&request)
        _ = try await execute(request: request, allowEmpty: true)
    }

    private func setAuthHeader(_ request: inout URLRequest) async throws {
        // Токен получаем каждый раз — OAuthTokenManager кеширует и авто-refresh'ит.
        // НЕ логируем токен.
        let token: String
        do {
            token = try await tokenManager.accessToken(forAccount: accountID)
        } catch {
            throw GraphMailError.authError("Не удалось получить access_token: \(error.localizedDescription)")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func execute(request: URLRequest, allowEmpty: Bool = false) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw GraphMailError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GraphMailError.networkError("Не HTTP-ответ")
        }

        switch http.statusCode {
        case 200, 201, 202, 204:
            return data
        case 401:
            // Токен истёк прямо во время запроса — принудительный refresh
            throw GraphMailError.authError("Token expired (401)")
        default:
            // Не логируем тело — может содержать PII
            throw GraphMailError.httpError(statusCode: http.statusCode, body: "HTTP \(http.statusCode)")
        }
    }

    // MARK: - JSON Parsing

    private func parseMessagesPage(data: Data) throws -> GraphPageResult<GraphMessage> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GraphMailError.parseError("Не JSON")
        }

        let nextLink = (json["@odata.nextLink"] as? String).flatMap { URL(string: $0) }
        let deltaLink = (json["@odata.deltaLink"] as? String).flatMap { URL(string: $0) }

        guard let value = json["value"] as? [[String: Any]] else {
            throw GraphMailError.parseError("Нет поля 'value' в ответе")
        }

        let messages = try value.map { try parseMessage(json: $0) }
        return GraphPageResult(items: messages, nextLink: nextLink, deltaLink: deltaLink)
    }

    private func parseMessage(json: [String: Any]) throws -> GraphMessage {
        guard let id = json["id"] as? String else {
            throw GraphMailError.parseError("Отсутствует id письма")
        }

        let subject = (json["subject"] as? String) ?? ""
        let isRead = (json["isRead"] as? Bool) ?? false
        let hasAttachments = (json["hasAttachments"] as? Bool) ?? false
        let bodyPreview = (json["bodyPreview"] as? String) ?? ""
        let internetMessageId = json["internetMessageId"] as? String
        let conversationId = json["conversationId"] as? String

        let from: MailAddress? = (json["from"] as? [String: Any])
            .flatMap { parseRecipient($0) }

        let toRecipients: [MailAddress] = ((json["toRecipients"] as? [[String: Any]]) ?? [])
            .compactMap { parseRecipient($0) }

        let receivedDateTime: Date
        if let dateStr = json["receivedDateTime"] as? String {
            receivedDateTime = ISO8601DateFormatter().date(from: dateStr) ?? Date.distantPast
        } else {
            receivedDateTime = Date.distantPast
        }

        return GraphMessage(
            id: id,
            subject: subject,
            from: from,
            toRecipients: toRecipients,
            receivedDateTime: receivedDateTime,
            isRead: isRead,
            hasAttachments: hasAttachments,
            bodyPreview: bodyPreview,
            internetMessageId: internetMessageId,
            conversationId: conversationId
        )
    }

    private func parseRecipient(_ json: [String: Any]) -> MailAddress? {
        guard let emailAddress = json["emailAddress"] as? [String: Any],
              let address = emailAddress["address"] as? String else {
            return nil
        }
        let name = emailAddress["name"] as? String
        return MailAddress(address: address, name: name)
    }

    private func parseFolderJSON(_ json: [String: Any]) -> GraphMailFolder? {
        guard let id = json["id"] as? String,
              let displayName = json["displayName"] as? String else {
            return nil
        }
        return GraphMailFolder(
            id: id,
            displayName: displayName,
            totalItemCount: (json["totalItemCount"] as? Int) ?? 0,
            unreadItemCount: (json["unreadItemCount"] as? Int) ?? 0,
            parentFolderId: json["parentFolderId"] as? String
        )
    }

    // MARK: - Constants

    /// Поля по умолчанию для запроса списка писем (без тела — для экономии трафика).
    public static let defaultMessageSelect: [String] = [
        "id",
        "subject",
        "from",
        "toRecipients",
        "receivedDateTime",
        "isRead",
        "hasAttachments",
        "bodyPreview",
        "internetMessageId",
        "conversationId"
    ]
}

// MARK: - URL+QueryItems helper

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
