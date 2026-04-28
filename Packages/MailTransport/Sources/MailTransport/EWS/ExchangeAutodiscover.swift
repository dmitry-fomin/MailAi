import Foundation
import Core

// MARK: - AutodiscoverResult

/// Результат autodiscover: настройки IMAP/SMTP/EWS для домена.
public struct AutodiscoverResult: Sendable, Equatable {
    /// IMAP endpoint (host + port + TLS).
    public let imapHost: String
    public let imapPort: Int
    public let imapTLS: Bool

    /// SMTP endpoint (host + port + TLS).
    public let smtpHost: String
    public let smtpPort: Int
    public let smtpStartTLS: Bool

    /// EWS URL, если обнаружен через autodiscover XML.
    public let ewsURL: URL?

    public init(
        imapHost: String, imapPort: Int, imapTLS: Bool,
        smtpHost: String, smtpPort: Int, smtpStartTLS: Bool,
        ewsURL: URL? = nil
    ) {
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapTLS = imapTLS
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpStartTLS = smtpStartTLS
        self.ewsURL = ewsURL
    }

    /// Fallback для Outlook.com / Exchange Online (известные значения).
    public static func outlookFallback() -> AutodiscoverResult {
        AutodiscoverResult(
            imapHost: "outlook.office365.com",
            imapPort: 993,
            imapTLS: true,
            smtpHost: "smtp.office365.com",
            smtpPort: 587,
            smtpStartTLS: true,
            ewsURL: URL(string: "https://outlook.office365.com/EWS/Exchange.asmx")
        )
    }
}

// MARK: - AutodiscoverError

public enum AutodiscoverError: Error, Sendable {
    /// Не удалось извлечь домен из email.
    case invalidEmail
    /// Ни один метод autodiscover не дал результата.
    case notFound
    /// HTTP-ошибка при запросе autodiscover.
    case httpError(Int)
    /// Ошибка парсинга XML.
    case parseError(String)
    /// Сетевая ошибка.
    case networkError(String)
}

// MARK: - ExchangeAutodiscover

/// Определяет настройки почтового сервера для Exchange/Outlook аккаунта.
///
/// Стратегия (по порядку):
/// 1. Autodiscover XML endpoint: `https://autodiscover.<domain>/autodiscover/autodiscover.xml`
/// 2. Альтернативный endpoint: `https://<domain>/autodiscover/autodiscover.xml`
/// 3. Outlook-specific: `https://autodiscover-s.outlook.com/autodiscover/autodiscover.xml`
/// 4. Hardcoded fallback: `outlook.office365.com:993` (TLS) + `smtp.office365.com:587` (STARTTLS).
///
/// XML-ответ парсится вручную (без XMLParser зависимости — используем NSXMLParser или String matching).
/// Если EWS URL найден — возвращается в результате для дальнейшего использования EWSClient.
public actor ExchangeAutodiscover {

    private let urlSession: URLSession
    private let connectTimeout: TimeInterval

    public init(connectTimeout: TimeInterval = 10) {
        self.connectTimeout = connectTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeout
        config.timeoutIntervalForResource = connectTimeout * 2
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Определяет настройки для указанного email-адреса.
    ///
    /// - Parameter email: Email в формате `user@domain`.
    /// - Returns: Настройки IMAP/SMTP/EWS.
    /// - Note: Никогда не выбрасывает — при неудаче всех попыток возвращает `.outlookFallback()`.
    public func discover(email: String) async -> AutodiscoverResult {
        guard let domain = extractDomain(from: email) else {
            return .outlookFallback()
        }

        // 1. Пробуем autodiscover XML (три endpoint'а)
        if let result = await tryAutodiscoverXML(email: email, domain: domain) {
            return result
        }

        // 2. Fallback
        return .outlookFallback()
    }

    // MARK: - Autodiscover XML

    private func tryAutodiscoverXML(email: String, domain: String) async -> AutodiscoverResult? {
        let candidates: [String] = [
            "https://autodiscover.\(domain)/autodiscover/autodiscover.xml",
            "https://\(domain)/autodiscover/autodiscover.xml",
            "https://autodiscover-s.outlook.com/autodiscover/autodiscover.xml"
        ]

        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            if let result = await requestAutodiscover(url: url, email: email) {
                return result
            }
        }
        return nil
    }

    /// Отправляет POX (Plain Old XML) autodiscover запрос.
    /// RFC: https://docs.microsoft.com/en-us/exchange/client-developer/web-service-reference/pox-autodiscover
    private func requestAutodiscover(url: URL, email: String) async -> AutodiscoverResult? {
        let body = autodiscoverRequestXML(email: email)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                return nil
            }
            return parseAutodiscoverResponse(data: data)
        } catch {
            return nil
        }
    }

    /// POX Autodiscover request XML (Exchange Autodiscover v1).
    private func autodiscoverRequestXML(email: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006">
          <Request>
            <EMailAddress>\(email)</EMailAddress>
            <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
          </Request>
        </Autodiscover>
        """
    }

    // MARK: - XML Parsing

    /// Парсит POX autodiscover ответ без внешних зависимостей.
    /// Ищет Protocol-блоки для IMAP, SMTP и EWS (ExchangeWebService).
    private func parseAutodiscoverResponse(data: Data) -> AutodiscoverResult? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }

        let parser = AutodiscoverXMLParser(xml: xml)
        return parser.parse()
    }

    // MARK: - Helpers

    private func extractDomain(from email: String) -> String? {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let domain = String(parts[1]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return domain.isEmpty ? nil : domain
    }
}

// MARK: - AutodiscoverXMLParser

/// Простой парсер POX Autodiscover XML ответа через NSXMLParser.
/// Не зависит от сторонних библиотек.
///
/// Структура ответа:
/// ```xml
/// <Account>
///   <AccountType>email</AccountType>
///   <Action>settings</Action>
///   <Protocol>
///     <Type>IMAP</Type>
///     <Server>imap.server.com</Server>
///     <Port>993</Port>
///     <SSL>on</SSL>
///   </Protocol>
/// </Account>
/// ```
private final class AutodiscoverXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private let xml: String

    // Parsing state
    private var currentProtocolType: String = ""
    private var currentServer: String = ""
    private var currentPort: Int = 0
    private var currentSSL: Bool = false
    private var currentLoginName: String = ""
    private var currentElement: String = ""
    private var inProtocol: Bool = false

    // Results
    private var imapServer: String?
    private var imapPort: Int = 993
    private var imapSSL: Bool = true
    private var smtpServer: String?
    private var smtpPort: Int = 587
    private var smtpStartTLS: Bool = true
    private var ewsURLString: String?

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> AutodiscoverResult? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        // Если нашли хотя бы IMAP или SMTP — возвращаем результат
        guard imapServer != nil || smtpServer != nil || ewsURLString != nil else {
            return nil
        }

        let ewsURL = ewsURLString.flatMap { URL(string: $0) }

        return AutodiscoverResult(
            imapHost: imapServer ?? "outlook.office365.com",
            imapPort: imapPort,
            imapTLS: imapSSL,
            smtpHost: smtpServer ?? "smtp.office365.com",
            smtpPort: smtpPort,
            smtpStartTLS: smtpStartTLS,
            ewsURL: ewsURL
        )
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Protocol" {
            inProtocol = true
            currentProtocolType = ""
            currentServer = ""
            currentPort = 0
            currentSSL = false
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        switch currentElement {
        case "Type":
            if inProtocol { currentProtocolType = value.uppercased() }
        case "Server":
            if inProtocol { currentServer = value }
        case "Port":
            if inProtocol { currentPort = Int(value) ?? 0 }
        case "SSL":
            if inProtocol { currentSSL = value.lowercased() == "on" }
        case "EwsUrl":
            ewsURLString = value
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "Protocol" && inProtocol {
            switch currentProtocolType {
            case "IMAP":
                if !currentServer.isEmpty {
                    imapServer = currentServer
                    if currentPort > 0 { imapPort = currentPort }
                    imapSSL = currentSSL
                }
            case "SMTP":
                if !currentServer.isEmpty {
                    smtpServer = currentServer
                    if currentPort > 0 { smtpPort = currentPort }
                    // STARTTLS обычно используется на 587; если SSL=on и порт 465 — implicit TLS.
                    smtpStartTLS = !(currentSSL && currentPort == 465)
                }
            case "EXCH", "EXPR":
                // EWS внутренний/внешний URL может быть в Protocol Type="EXPR"
                // Если EwsUrl ещё не найден через <EwsUrl> элемент
                if ewsURLString == nil, !currentServer.isEmpty {
                    // Строим EWS URL из server
                    ewsURLString = "https://\(currentServer)/EWS/Exchange.asmx"
                }
            default:
                break
            }
            inProtocol = false
        }
        currentElement = ""
    }
}
