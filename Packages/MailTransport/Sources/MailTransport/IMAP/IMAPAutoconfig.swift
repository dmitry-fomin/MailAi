import Foundation
import Network

// MARK: - AutoconfigResult

/// Результат автоопределения настроек IMAP/SMTP для почтового домена.
public struct AutoconfigResult: Sendable, Equatable {
    public let imapHost: String
    public let imapPort: Int
    public let imapSecurity: MailServerSecurity

    public let smtpHost: String
    public let smtpPort: Int
    public let smtpSecurity: MailServerSecurity

    /// Источник, из которого получены настройки (для отладки/UI).
    public let source: AutoconfigSource

    public init(
        imapHost: String,
        imapPort: Int,
        imapSecurity: MailServerSecurity,
        smtpHost: String,
        smtpPort: Int,
        smtpSecurity: MailServerSecurity,
        source: AutoconfigSource
    ) {
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSecurity = imapSecurity
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.source = source
    }
}

// MARK: - AutoconfigSource

/// Источник настроек — помогает пользователю понять, насколько данные надёжны.
public enum AutoconfigSource: String, Sendable, Equatable {
    /// Известный провайдер из встроенной базы (самый надёжный).
    case knownProvider
    /// Mozilla Autoconfig с домена провайдера (`autoconfig.<domain>`).
    case mozillaAutoconfigDomain
    /// Mozilla Autoconfig с Thunderbird ISPDB (`autoconfig.thunderbird.net`).
    case mozillaAutoconfigThunderbird
    /// .well-known/autoconfig на домене.
    case wellKnown
    /// Предположение на основе MX-записи (наименее надёжный).
    case mxFallback
}

// MARK: - AutoconfigError

public enum AutoconfigError: Error, Sendable {
    /// Email не содержит `@` или домен пустой.
    case invalidEmail
    /// Не удалось определить настройки никаким методом.
    case notFound
}

// MARK: - IMAPAutoconfig

/// Автоматически определяет настройки IMAP/SMTP для почтового адреса.
///
/// Стратегия (по приоритету):
/// 1. `EmailProviderDB` — мгновенный поиск по известным провайдерам.
/// 2. Mozilla Autoconfig на домене: `https://autoconfig.<domain>/mail/config-v1.1.xml`
/// 3. Mozilla Autoconfig на Thunderbird ISPDB: `https://autoconfig.thunderbird.net/v1.1/<domain>`
/// 4. `.well-known`: `https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml`
/// 5. MX-запись: определяем MX-хост и строим предположение об IMAP/SMTP.
///
/// Тела писем и любые личные данные через этот класс не проходят.
public actor IMAPAutoconfig {

    private let urlSession: URLSession
    private let requestTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 8) {
        self.requestTimeout = requestTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        // Не кешируем — данные должны быть актуальными.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Определяет настройки IMAP/SMTP для указанного email-адреса.
    ///
    /// - Parameter email: Адрес в формате `user@example.com`.
    /// - Returns: `AutoconfigResult` с настройками сервера.
    /// - Throws: `AutoconfigError.invalidEmail` если email некорректен,
    ///           `AutoconfigError.notFound` если ни один метод не дал результата.
    public func discover(email: String) async throws -> AutoconfigResult {
        guard let domain = extractDomain(from: email) else {
            throw AutoconfigError.invalidEmail
        }

        // 1. Известный провайдер — самый быстрый путь.
        if let config = EmailProviderDB.config(forDomain: domain) {
            return AutoconfigResult(from: config, source: .knownProvider)
        }

        // 2–4. Сетевые методы запускаем параллельно для скорости,
        //       но соблюдаем приоритет через упорядоченный перебор результатов.
        async let domainAutoconfig = fetchMozillaAutoconfig(domain: domain, variant: .domainHosted)
        async let thunderbirdAutoconfig = fetchMozillaAutoconfig(domain: domain, variant: .thunderbird)
        async let wellKnown = fetchWellKnown(domain: domain)

        // Ждём все три — берём первый успешный по приоритету.
        let results = await (domainAutoconfig, thunderbirdAutoconfig, wellKnown)

        if let result = results.0 { return result }
        if let result = results.1 { return result }
        if let result = results.2 { return result }

        // 5. MX fallback — последняя надежда.
        if let result = await mxFallback(domain: domain) {
            return result
        }

        throw AutoconfigError.notFound
    }

    // MARK: - Mozilla Autoconfig

    private enum MozillaVariant {
        case domainHosted   // https://autoconfig.<domain>/mail/config-v1.1.xml
        case thunderbird    // https://autoconfig.thunderbird.net/v1.1/<domain>
    }

    private func fetchMozillaAutoconfig(domain: String, variant: MozillaVariant) async -> AutoconfigResult? {
        let urlString: String
        let source: AutoconfigSource

        switch variant {
        case .domainHosted:
            urlString = "https://autoconfig.\(domain)/mail/config-v1.1.xml"
            source = .mozillaAutoconfigDomain
        case .thunderbird:
            urlString = "https://autoconfig.thunderbird.net/v1.1/\(domain)"
            source = .mozillaAutoconfigThunderbird
        }

        guard let url = URL(string: urlString) else { return nil }
        guard let data = await fetchData(from: url) else { return nil }
        return MozillaAutoconfigParser(source: source).parse(data: data)
    }

    // MARK: - .well-known

    private func fetchWellKnown(domain: String) async -> AutoconfigResult? {
        let urlString = "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml"
        guard let url = URL(string: urlString) else { return nil }
        guard let data = await fetchData(from: url) else { return nil }
        return MozillaAutoconfigParser(source: .wellKnown).parse(data: data)
    }

    // MARK: - MX Fallback

    /// Запрашивает MX-запись домена и строит предположение об IMAP/SMTP хостах.
    ///
    /// Логика: если MX-хост содержит "google" — gmail, "outlook/microsoft" — Outlook,
    /// иначе строим `imap.<mx-domain>` и `smtp.<mx-domain>`.
    private func mxFallback(domain: String) async -> AutoconfigResult? {
        guard let mxHost = await resolveMX(domain: domain) else { return nil }

        // Проверяем, не ведёт ли MX к известному провайдеру.
        let mxLower = mxHost.lowercased()

        if mxLower.contains("google") || mxLower.contains("gmail") {
            if let config = EmailProviderDB.config(forDomain: "gmail.com") {
                return AutoconfigResult(from: config, source: .mxFallback)
            }
        }

        if mxLower.contains("outlook") || mxLower.contains("microsoft") || mxLower.contains("office365") {
            if let config = EmailProviderDB.config(forDomain: "outlook.com") {
                return AutoconfigResult(from: config, source: .mxFallback)
            }
        }

        if mxLower.contains("yandex") {
            if let config = EmailProviderDB.config(forDomain: "yandex.ru") {
                return AutoconfigResult(from: config, source: .mxFallback)
            }
        }

        if mxLower.contains("mail.ru") {
            if let config = EmailProviderDB.config(forDomain: "mail.ru") {
                return AutoconfigResult(from: config, source: .mxFallback)
            }
        }

        // Строим предположение: imap.<mx-root-domain> и smtp.<mx-root-domain>
        let rootDomain = extractRootDomain(from: mxHost) ?? domain
        return AutoconfigResult(
            imapHost: "imap.\(rootDomain)",
            imapPort: 993,
            imapSecurity: .ssl,
            smtpHost: "smtp.\(rootDomain)",
            smtpPort: 587,
            smtpSecurity: .startTLS,
            source: .mxFallback
        )
    }

    // MARK: - DNS MX Resolution

    /// Разрешает MX-запись через `host` CLI-утилиту (доступна на macOS).
    ///
    /// Используется только как последний fallback — не критично по скорости.
    private func resolveMX(domain: String) async -> String? {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                // Безопасно: domain уже нормализован (lowercased, нет спецсимволов).
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/host")
                process.arguments = ["-t", "MX", domain]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let host = Self.parseMXFromHostOutput(output)
                    continuation.resume(returning: host)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Парсит вывод `host -t MX domain.com`.
    /// Пример строки: `example.com mail is handled by 10 mail.example.com.`
    private static func parseMXFromHostOutput(_ output: String) -> String? {
        // Формат: "<domain> mail is handled by <priority> <host>."
        let lines = output.components(separatedBy: .newlines)
        var bestPriority = Int.max
        var bestHost: String?

        for line in lines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Минимальный формат: [..., "by", "<priority>", "<host>"]
            guard parts.count >= 2,
                  let byIndex = parts.firstIndex(of: "by"),
                  byIndex + 2 < parts.count else { continue }

            let priorityStr = parts[byIndex + 1]
            let rawHost = parts[byIndex + 2]

            guard let priority = Int(priorityStr) else { continue }

            // Убираем завершающую точку из FQDN.
            let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
            guard !host.isEmpty else { continue }

            if priority < bestPriority {
                bestPriority = priority
                bestHost = host
            }
        }

        return bestHost
    }

    // MARK: - Helpers

    private func fetchData(from url: URL) async -> Data? {
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func extractDomain(from email: String) -> String? {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let domain = String(parts[1]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return domain.isEmpty ? nil : domain
    }

    /// Извлекает корневой домен из FQDN (например `mx1.example.co.uk` → `example.co.uk`).
    /// Упрощённая эвристика: берём последние 2 компонента (или 3 для ccTLD второго уровня).
    private func extractRootDomain(from host: String) -> String? {
        let components = host.split(separator: ".").map(String.init)
        guard components.count >= 2 else { return nil }

        // Эвристика для ccTLD вида `.co.uk`, `.com.br`, `.org.au` и т.д.
        let twoPartTLDs: Set<String> = [
            "co.uk", "co.jp", "co.nz", "co.in", "co.za",
            "com.br", "com.au", "com.ar", "org.uk", "net.au"
        ]
        if components.count >= 3 {
            let possibleTLD = "\(components[components.count - 2]).\(components[components.count - 1])"
            if twoPartTLDs.contains(possibleTLD) {
                return components.suffix(3).joined(separator: ".")
            }
        }

        return components.suffix(2).joined(separator: ".")
    }
}

// MARK: - AutoconfigResult + ProviderConfig

private extension AutoconfigResult {
    init(from config: ProviderConfig, source: AutoconfigSource) {
        self.init(
            imapHost: config.imap.host,
            imapPort: config.imap.port,
            imapSecurity: config.imap.security,
            smtpHost: config.smtp.host,
            smtpPort: config.smtp.port,
            smtpSecurity: config.smtp.security,
            source: source
        )
    }
}

// MARK: - MozillaAutoconfigParser

/// Парсит Mozilla Autoconfig XML (ISP Database формат).
///
/// Спецификация: https://wiki.mozilla.org/Thunderbird:Autoconfiguration:ConfigFileFormat
///
/// Пример XML:
/// ```xml
/// <clientConfig version="1.1">
///   <emailProvider id="gmail.com">
///     <incomingServer type="imap">
///       <hostname>imap.gmail.com</hostname>
///       <port>993</port>
///       <socketType>SSL</socketType>
///       <authentication>OAuth2</authentication>
///     </incomingServer>
///     <outgoingServer type="smtp">
///       <hostname>smtp.gmail.com</hostname>
///       <port>587</port>
///       <socketType>STARTTLS</socketType>
///     </outgoingServer>
///   </emailProvider>
/// </clientConfig>
/// ```
private final class MozillaAutoconfigParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private let source: AutoconfigSource

    // Parsing state
    private var currentElement: String = ""
    private var inIncoming: Bool = false
    private var inOutgoing: Bool = false
    private var currentText: String = ""

    // Accumulated values per server block
    private var incomingHostname: String?
    private var incomingPort: Int?
    private var incomingSocketType: String?

    private var outgoingHostname: String?
    private var outgoingPort: Int?
    private var outgoingSocketType: String?

    init(source: AutoconfigSource) {
        self.source = source
    }

    func parse(data: Data) -> AutoconfigResult? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        guard let imapHost = incomingHostname,
              let smtpHost = outgoingHostname else {
            return nil
        }

        let imapPort = incomingPort ?? 993
        let smtpPort = outgoingPort ?? 587
        let imapSecurity = security(from: incomingSocketType, defaultPort: imapPort)
        let smtpSecurity = security(from: outgoingSocketType, defaultPort: smtpPort)

        return AutoconfigResult(
            imapHost: imapHost,
            imapPort: imapPort,
            imapSecurity: imapSecurity,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpSecurity: smtpSecurity,
            source: source
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
        currentText = ""

        switch elementName {
        case "incomingServer":
            // Берём только первый IMAP (type="imap"), игнорируем POP3.
            if attributes["type"]?.lowercased() == "imap", incomingHostname == nil {
                inIncoming = true
                inOutgoing = false
            }
        case "outgoingServer":
            if attributes["type"]?.lowercased() == "smtp", outgoingHostname == nil {
                inOutgoing = true
                inIncoming = false
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inIncoming {
            switch elementName {
            case "hostname": incomingHostname = value.isEmpty ? nil : value
            case "port": incomingPort = Int(value)
            case "socketType": incomingSocketType = value
            case "incomingServer": inIncoming = false
            default: break
            }
        } else if inOutgoing {
            switch elementName {
            case "hostname": outgoingHostname = value.isEmpty ? nil : value
            case "port": outgoingPort = Int(value)
            case "socketType": outgoingSocketType = value
            case "outgoingServer": inOutgoing = false
            default: break
            }
        }

        currentText = ""
    }

    // MARK: - Helpers

    private func security(from socketType: String?, defaultPort: Int) -> MailServerSecurity {
        switch socketType?.uppercased() {
        case "SSL":
            return .ssl
        case "STARTTLS":
            return .startTLS
        case "PLAIN", "NONE":
            return .none
        default:
            // Угадываем по порту.
            switch defaultPort {
            case 993, 465: return .ssl
            case 587, 143: return .startTLS
            default: return .ssl
            }
        }
    }
}
