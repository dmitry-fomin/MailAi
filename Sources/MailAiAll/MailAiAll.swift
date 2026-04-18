/// Агрегирующий re-export всех модулей MailAi. Используется CI/скриптами
/// для одной точки сборки (`swift build` из корня).
@_exported import Core
@_exported import Secrets
@_exported import Storage
@_exported import MailTransport
@_exported import AI
@_exported import UI
@_exported import MockData
@_exported import AppShell

public enum MailAiApp {
    public static let version = "0.1.0-alpha"
}
