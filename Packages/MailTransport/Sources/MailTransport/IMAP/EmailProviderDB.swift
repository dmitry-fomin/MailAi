import Foundation

// MARK: - MailServerSecurity

/// Метод защиты соединения с почтовым сервером.
public enum MailServerSecurity: String, Sendable, Equatable, Codable {
    /// Соединение без шифрования (не рекомендуется).
    case none
    /// SSL/TLS с самого начала (implicit TLS).
    case ssl
    /// STARTTLS — TLS поверх plaintext-соединения.
    case startTLS
}

// MARK: - ProviderServerConfig

/// Настройки одного сервера (IMAP или SMTP) из провайдер-базы.
public struct ProviderServerConfig: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let security: MailServerSecurity

    public init(host: String, port: Int, security: MailServerSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

// MARK: - ProviderConfig

/// Полные настройки почтового провайдера (IMAP + SMTP).
public struct ProviderConfig: Sendable, Equatable {
    public let displayName: String
    public let imap: ProviderServerConfig
    public let smtp: ProviderServerConfig

    public init(displayName: String, imap: ProviderServerConfig, smtp: ProviderServerConfig) {
        self.displayName = displayName
        self.imap = imap
        self.smtp = smtp
    }
}

// MARK: - EmailProviderDB

/// Словарь известных почтовых провайдеров: домен → настройки IMAP/SMTP.
///
/// Используется как первый быстрый шаг в `IMAPAutoconfig` перед сетевыми запросами.
/// Покрывает самые популярные провайдеры в России и мире.
public enum EmailProviderDB {

    // MARK: - Lookup

    /// Возвращает конфигурацию по домену, если он известен.
    ///
    /// - Parameter domain: Домен в нижнем регистре (например, `"gmail.com"`).
    /// - Returns: `ProviderConfig` если домен известен, иначе `nil`.
    public static func config(forDomain domain: String) -> ProviderConfig? {
        let key = domain.lowercased()
        return knownProviders[key]
    }

    // MARK: - Known Providers

    /// Полный словарь известных провайдеров.
    /// Ключ — домен в нижнем регистре.
    private static let knownProviders: [String: ProviderConfig] = {
        var db: [String: ProviderConfig] = [:]

        // MARK: Google / Gmail
        let gmail = ProviderConfig(
            displayName: "Gmail",
            imap: ProviderServerConfig(host: "imap.gmail.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.gmail.com", port: 587, security: .startTLS)
        )
        for domain in ["gmail.com", "googlemail.com"] {
            db[domain] = gmail
        }

        // MARK: Microsoft Outlook / Hotmail / Live
        let outlook = ProviderConfig(
            displayName: "Outlook",
            imap: ProviderServerConfig(host: "outlook.office365.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.office365.com", port: 587, security: .startTLS)
        )
        for domain in [
            "outlook.com", "hotmail.com", "hotmail.co.uk", "hotmail.fr",
            "hotmail.de", "hotmail.it", "hotmail.es", "live.com", "live.co.uk",
            "live.fr", "live.de", "live.ru", "msn.com"
        ] {
            db[domain] = outlook
        }

        // MARK: Yandex
        let yandex = ProviderConfig(
            displayName: "Яндекс Почта",
            imap: ProviderServerConfig(host: "imap.yandex.ru", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.yandex.ru", port: 465, security: .ssl)
        )
        for domain in ["yandex.ru", "yandex.ua", "yandex.kz", "yandex.by", "ya.ru", "narod.ru"] {
            db[domain] = yandex
        }

        // MARK: Mail.ru
        let mailru = ProviderConfig(
            displayName: "Mail.ru",
            imap: ProviderServerConfig(host: "imap.mail.ru", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.mail.ru", port: 465, security: .ssl)
        )
        for domain in ["mail.ru", "inbox.ru", "list.ru", "bk.ru"] {
            db[domain] = mailru
        }

        // MARK: iCloud
        let icloud = ProviderConfig(
            displayName: "iCloud Mail",
            imap: ProviderServerConfig(host: "imap.mail.me.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        )
        for domain in ["icloud.com", "me.com", "mac.com"] {
            db[domain] = icloud
        }

        // MARK: Rambler
        let rambler = ProviderConfig(
            displayName: "Rambler Почта",
            imap: ProviderServerConfig(host: "imap.rambler.ru", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.rambler.ru", port: 465, security: .ssl)
        )
        for domain in ["rambler.ru", "lenta.ru", "myrambler.ru", "ro.ru"] {
            db[domain] = rambler
        }

        // MARK: ProtonMail (Bridge)
        let proton = ProviderConfig(
            displayName: "ProtonMail (Bridge)",
            imap: ProviderServerConfig(host: "127.0.0.1", port: 1143, security: .startTLS),
            smtp: ProviderServerConfig(host: "127.0.0.1", port: 1025, security: .startTLS)
        )
        for domain in ["proton.me", "protonmail.com", "protonmail.ch", "pm.me"] {
            db[domain] = proton
        }

        // MARK: Apple (системные)
        let appleExchange = ProviderConfig(
            displayName: "Apple",
            imap: ProviderServerConfig(host: "imap.apple.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.apple.com", port: 587, security: .startTLS)
        )
        db["apple.com"] = appleExchange

        // MARK: Fastmail
        let fastmail = ProviderConfig(
            displayName: "Fastmail",
            imap: ProviderServerConfig(host: "imap.fastmail.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.fastmail.com", port: 587, security: .startTLS)
        )
        for domain in ["fastmail.com", "fastmail.fm", "fastmail.net", "fastmail.org"] {
            db[domain] = fastmail
        }

        // MARK: Zoho Mail
        let zoho = ProviderConfig(
            displayName: "Zoho Mail",
            imap: ProviderServerConfig(host: "imap.zoho.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.zoho.com", port: 587, security: .startTLS)
        )
        db["zoho.com"] = zoho

        // MARK: AOL
        let aol = ProviderConfig(
            displayName: "AOL Mail",
            imap: ProviderServerConfig(host: "imap.aol.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.aol.com", port: 587, security: .startTLS)
        )
        db["aol.com"] = aol

        // MARK: Yahoo
        let yahoo = ProviderConfig(
            displayName: "Yahoo Mail",
            imap: ProviderServerConfig(host: "imap.mail.yahoo.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.mail.yahoo.com", port: 587, security: .startTLS)
        )
        for domain in ["yahoo.com", "yahoo.co.uk", "yahoo.de", "yahoo.fr", "yahoo.es", "ymail.com"] {
            db[domain] = yahoo
        }

        // MARK: GMX
        let gmx = ProviderConfig(
            displayName: "GMX",
            imap: ProviderServerConfig(host: "imap.gmx.com", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "mail.gmx.com", port: 587, security: .startTLS)
        )
        for domain in ["gmx.com", "gmx.de", "gmx.at", "gmx.ch", "gmx.net"] {
            db[domain] = gmx
        }

        // MARK: Web.de
        let webde = ProviderConfig(
            displayName: "Web.de",
            imap: ProviderServerConfig(host: "imap.web.de", port: 993, security: .ssl),
            smtp: ProviderServerConfig(host: "smtp.web.de", port: 587, security: .startTLS)
        )
        db["web.de"] = webde

        return db
    }()
}
