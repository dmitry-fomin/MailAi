import Foundation
import Core

// MARK: - OAuthProvider

/// Провайдер OAuth2 — определяет endpoint'ы для конкретного сервиса.
public enum OAuthProvider: Sendable, Equatable {
    /// Google OAuth2 (Gmail).
    case google
    /// Microsoft OAuth2 (Outlook / Exchange Online).
    case microsoft

    /// Endpoint для обмена refresh_token → access_token.
    public var tokenEndpoint: URL {
        switch self {
        case .google:
            // Google Token endpoint (RFC 6749 §6).
            return URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft:
            // Microsoft Identity Platform — common endpoint (multi-tenant).
            return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        }
    }

    /// Scope для IMAP/SMTP доступа.
    public var imapScope: String {
        switch self {
        case .google:
            return "https://mail.google.com/"
        case .microsoft:
            return "https://outlook.office.com/IMAP.AccessAsUser.All offline_access"
        }
    }
}

// MARK: - OAuthToken

/// Пара токенов OAuth2: access_token (краткоживущий) + refresh_token (долгоживущий).
public struct OAuthToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Время истечения access_token. Nil если сервер не вернул expires_in.
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Истекает ли токен в ближайшие `seconds` секунд (по умолчанию 60).
    public func isExpiringSoon(within seconds: TimeInterval = 60) -> Bool {
        guard let exp = expiresAt else { return false }
        return Date().addingTimeInterval(seconds) >= exp
    }
}

// MARK: - OAuthError

public enum OAuthError: Error, Sendable, Equatable {
    /// Refresh token отсутствует в Keychain для данного аккаунта.
    case noRefreshToken
    /// Сервер вернул ошибку при refresh (например, token revoked).
    case refreshFailed(statusCode: Int, body: String)
    /// Ответ сервера не содержит access_token.
    case invalidResponse
    /// Сетевая ошибка.
    case networkError(String)
}

// MARK: - OAuthTokenManager

/// Менеджер OAuth2 токенов для Gmail и Outlook.
///
/// Хранит `access_token` и `refresh_token` в Keychain через `KeychainService`.
/// Автоматически обновляет `access_token` за 60 секунд до истечения.
/// Thread-safe: actor.
///
/// Использование:
/// ```swift
/// let manager = OAuthTokenManager(
///     provider: .google,
///     clientID: "...",
///     clientSecret: "...",
///     keychain: KeychainService()
/// )
/// // Сохранить токены после авторизации:
/// try await manager.store(token: oauthToken, forAccount: accountID)
/// // Получить свежий access_token (авто-refresh если нужно):
/// let accessToken = try await manager.accessToken(forAccount: accountID)
/// ```
///
/// Безопасность: `access_token` и `refresh_token` хранятся только в Keychain.
/// Они никогда не попадают в логи, crash-репорты или на диск вне Keychain.
public actor OAuthTokenManager {

    // MARK: - Keychain key suffixes

    /// Суффиксы ключей Keychain для хранения токенов.
    private enum TokenKind: String {
        case accessToken  = "oauth_access"
        case refreshToken = "oauth_refresh"
        case expiresAt    = "oauth_expires"
    }

    // MARK: - Dependencies

    private let provider: OAuthProvider
    private let clientID: String
    private let clientSecret: String
    private let keychain: KeychainService
    private let urlSession: URLSession

    // MARK: - In-memory cache

    /// Кешируем токены в памяти чтобы не дёргать Keychain на каждый запрос.
    /// Инвалидируется при refresh.
    private var cache: [Account.ID: OAuthToken] = [:]

    // MARK: - Init

    public init(
        provider: OAuthProvider,
        clientID: String,
        clientSecret: String,
        keychain: KeychainService,
        urlSession: URLSession = .shared
    ) {
        self.provider = provider
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.keychain = keychain
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Возвращает свежий access_token для аккаунта.
    /// Автоматически обновляет через refresh_token если истекает в ближайшие 60 секунд.
    public func accessToken(forAccount accountID: Account.ID) async throws -> String {
        // Проверяем кеш
        if let cached = cache[accountID], !cached.isExpiringSoon() {
            return cached.accessToken
        }

        // Пробуем загрузить из Keychain
        let stored = try await loadFromKeychain(accountID: accountID)
        if let token = stored, !token.isExpiringSoon() {
            cache[accountID] = token
            return token.accessToken
        }

        // Нужен refresh
        return try await refreshAndStore(accountID: accountID, existing: stored)
    }

    /// Сохраняет токены в Keychain после первоначальной авторизации.
    public func store(token: OAuthToken, forAccount accountID: Account.ID) async throws {
        try await saveToKeychain(token: token, accountID: accountID)
        cache[accountID] = token
    }

    /// Инвалидирует кеш и удаляет токены из Keychain (logout).
    public func revoke(forAccount accountID: Account.ID) async throws {
        cache.removeValue(forKey: accountID)
        try await keychain.delete(kind: .oauthRefreshToken, forAccount: accountID)
        // access_token и expiresAt хранятся через password/smtpPassword слоты — очищаем
        // через вспомогательные ключи в KeychainService.
        // Используем кастомные kind: здесь мы не можем передать произвольный string в Kind,
        // поэтому храним access_token через Kind.password (переопределяем ниже через raw set).
        // Удаляем все три ключа.
        try? await deleteOAuthKey(kind: .accessToken, accountID: accountID)
        try? await deleteOAuthKey(kind: .expiresAt, accountID: accountID)
    }

    /// Принудительно обновляет токен (вызывается при получении 401 от SMTP/IMAP).
    public func forceRefresh(forAccount accountID: Account.ID) async throws -> String {
        cache.removeValue(forKey: accountID)
        let stored = try await loadFromKeychain(accountID: accountID)
        return try await refreshAndStore(accountID: accountID, existing: stored)
    }

    // MARK: - Token refresh

    private func refreshAndStore(accountID: Account.ID, existing: OAuthToken?) async throws -> String {
        let refreshToken: String
        if let token = existing?.refreshToken {
            refreshToken = token
        } else if let token = try await keychain.value(kind: .oauthRefreshToken, forAccount: accountID) {
            refreshToken = token
        } else {
            throw OAuthError.noRefreshToken
        }

        let newToken = try await performRefresh(refreshToken: refreshToken)
        try await saveToKeychain(token: newToken, accountID: accountID)
        cache[accountID] = newToken
        return newToken.accessToken
    }

    /// Выполняет HTTP-запрос к token endpoint для обмена refresh_token → access_token.
    private func performRefresh(refreshToken: String) async throws -> OAuthToken {
        var request = URLRequest(url: provider.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // RFC 6749 §6: grant_type=refresh_token
        let params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw OAuthError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.networkError("Не HTTP-ответ")
        }
        guard http.statusCode == 200 else {
            // Не логируем тело ответа — может содержать частичные токены
            throw OAuthError.refreshFailed(
                statusCode: http.statusCode,
                body: "HTTP \(http.statusCode)"
            )
        }

        // Парсим JSON ответ
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String
        else {
            throw OAuthError.invalidResponse
        }

        // refresh_token в ответе — опционален (Google возвращает только при первом запросе)
        let newRefreshToken = (json["refresh_token"] as? String) ?? refreshToken

        let expiresAt: Date?
        if let expiresIn = json["expires_in"] as? TimeInterval {
            expiresAt = Date().addingTimeInterval(expiresIn)
        } else if let expiresIn = json["expires_in"] as? Int {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            expiresAt = nil
        }

        return OAuthToken(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAt: expiresAt
        )
    }

    // MARK: - Keychain persistence

    /// Сохраняет токен в Keychain. Значения хранятся отдельными записями
    /// с суффиксами в service-ключе — не смешиваем с IMAP-паролями.
    private func saveToKeychain(token: OAuthToken, accountID: Account.ID) async throws {
        // refresh_token — через стандартный KeychainService.Kind.oauthRefreshToken
        try await keychain.set(value: token.refreshToken, kind: .oauthRefreshToken, forAccount: accountID)
        // access_token и expiresAt — через кастомные ключи
        try await setOAuthKey(kind: .accessToken, value: token.accessToken, accountID: accountID)
        if let exp = token.expiresAt {
            try await setOAuthKey(kind: .expiresAt, value: String(exp.timeIntervalSince1970), accountID: accountID)
        }
    }

    private func loadFromKeychain(accountID: Account.ID) async throws -> OAuthToken? {
        guard let refreshToken = try await keychain.value(kind: .oauthRefreshToken, forAccount: accountID),
              !refreshToken.isEmpty else {
            return nil
        }
        let accessToken = try await getOAuthKey(kind: .accessToken, accountID: accountID)
        let expiresAtStr = try await getOAuthKey(kind: .expiresAt, accountID: accountID)
        let expiresAt = expiresAtStr.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }

        return OAuthToken(
            accessToken: accessToken ?? "",
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    // MARK: - Custom Keychain key helpers

    /// Создаём отдельные Keychain-записи для access_token и expiresAt
    /// используя прямой Security framework через вспомогательный KeychainService.
    /// Service-ключ: "mailai.<accountID>.oauth_access" / "mailai.<accountID>.oauth_expires"
    private func setOAuthKey(kind: TokenKind, value: String, accountID: Account.ID) async throws {
        // Используем KeychainService как bridge: он умеет работать с произвольным Kind,
        // но Kind — enum. Создаём синтетический account-ключ через makeService вручную.
        // Вместо этого — используем InMemorySecretsStore-trick: храним через
        // кастомный service-ключ напрямую через Security (без зависимости от Kind enum).
        // Упрощение: используем KeychainService.Kind.password с префиксом в accountID.
        // Так мы не меняем публичный API KeychainService.
        let prefixedID = Account.ID(rawValue: "\(accountID.rawValue).__\(kind.rawValue)")
        try await keychain.set(value: value, kind: .password, forAccount: prefixedID)
    }

    private func getOAuthKey(kind: TokenKind, accountID: Account.ID) async throws -> String? {
        let prefixedID = Account.ID(rawValue: "\(accountID.rawValue).__\(kind.rawValue)")
        return try await keychain.value(kind: .password, forAccount: prefixedID)
    }

    private func deleteOAuthKey(kind: TokenKind, accountID: Account.ID) async throws {
        let prefixedID = Account.ID(rawValue: "\(accountID.rawValue).__\(kind.rawValue)")
        try await keychain.delete(kind: .password, forAccount: prefixedID)
    }
}

// MARK: - SASL XOAUTH2

/// Утилита для формирования строки SASL XOAUTH2 (RFC 7628).
/// Используется для аутентификации IMAP/SMTP через OAuth2.
///
/// Формат: base64("user=<email>\x01auth=Bearer <token>\x01\x01")
public enum XOAUTH2 {
    /// Формирует base64-encoded SASL XOAUTH2 строку.
    /// - Parameters:
    ///   - email: Email аккаунта.
    ///   - accessToken: Свежий OAuth2 access_token.
    public static func encode(email: String, accessToken: String) -> String {
        let raw = "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }
}
