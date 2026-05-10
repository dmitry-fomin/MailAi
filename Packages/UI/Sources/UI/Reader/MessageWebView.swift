// Packages/UI/Sources/UI/Reader/MessageWebView.swift
import SwiftUI
import WebKit
import AppKit

/// SwiftUI-обёртка над WKWebView для отображения HTML-письма.
///
/// Поддерживает:
/// - Отключённый JavaScript (`allowsContentJavaScript = false`)
/// - Блокировку удалённых ресурсов через CSP (управляется `HTMLPreprocessor`)
/// - Масштабирование текста через `textZoom` (1.0 = 100%)
/// - Открытие ссылок в браузере
/// - Fallback на plain text — на уровне `ReaderBodyView`
public struct MessageWebView: NSViewRepresentable {
    public let processedEmail: ProcessedEmail
    public let messageID: String
    public let cacheManager: CacheManager
    /// Масштаб текста: 1.0 = 100%, 1.2 = 120%, 0.85 = 85%.
    public var textZoom: Double

    public init(
        processedEmail: ProcessedEmail,
        messageID: String,
        cacheManager: CacheManager,
        textZoom: Double = 1.0
    ) {
        self.processedEmail = processedEmail
        self.messageID = messageID
        self.cacheManager = cacheManager
        self.textZoom = textZoom
    }

    public func makeNSView(context: Context) -> WKWebView {
        let handler = MailCIDSchemeHandler { msgID, contentID in
            await cacheManager.readAttachment(messageID: msgID, contentID: contentID)
        }
        let config = WKWebViewConfiguration()
        // JavaScript отключён — письма не должны выполнять скрипты
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(handler, forURLScheme: "cid")
        config.preferences.setValue(false, forKey: "allowFileAccessFromFileURLs")

        let controller = MessageWebViewController(
            configuration: config,
            cidHandler: handler,
            processedEmail: processedEmail,
            messageID: messageID,
            textZoom: textZoom
        )
        context.coordinator.viewController = controller
        return controller.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let vc = context.coordinator.viewController else { return }
        // Обновляем масштаб без перезагрузки страницы
        if nsView.pageZoom != textZoom {
            nsView.pageZoom = textZoom
        }
        if vc.currentMessageID != messageID {
            vc.load(processedEmail: processedEmail, messageID: messageID)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var viewController: MessageWebViewController?
    }
}

/// Управляет WKWebView: загрузка HTML, тёмная тема, навигация.
///
/// Тёмная тема инжектируется непосредственно в HTML перед `loadHTMLString`,
/// так как `allowsContentJavaScript = false` исключает использование `evaluateJavaScript`
/// для модификации DOM после загрузки страницы.
public final class MessageWebViewController: NSObject, WKNavigationDelegate, @unchecked Sendable {
    public let webView: WKWebView
    private let cidHandler: MailCIDSchemeHandler
    public private(set) var currentMessageID: String = ""
    private var lastProcessedEmail: ProcessedEmail?

    public init(
        configuration: WKWebViewConfiguration,
        cidHandler: MailCIDSchemeHandler,
        processedEmail: ProcessedEmail,
        messageID: String,
        textZoom: Double = 1.0
    ) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.cidHandler = cidHandler
        super.init()
        self.webView.navigationDelegate = self
        self.webView.pageZoom = textZoom
        load(processedEmail: processedEmail, messageID: messageID)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: NSNotification.Name("NSSystemColorsDidChangeNotification"),
            object: nil
        )
    }

    public func load(processedEmail: ProcessedEmail, messageID: String) {
        currentMessageID = messageID
        lastProcessedEmail = processedEmail
        cidHandler.setCurrentMessage(messageID)

        let htmlToLoad = htmlWithDarkModeIfNeeded(
            processedEmail.html,
            hasDarkModeSupport: processedEmail.hasDarkModeSupport
        )
        webView.loadHTMLString(htmlToLoad, baseURL: URL(string: "about:blank"))
    }

    // MARK: - Dark mode

    @objc private func appearanceDidChange() {
        guard let email = lastProcessedEmail, !currentMessageID.isEmpty else { return }
        let htmlToLoad = htmlWithDarkModeIfNeeded(
            email.html,
            hasDarkModeSupport: email.hasDarkModeSupport
        )
        webView.loadHTMLString(htmlToLoad, baseURL: URL(string: "about:blank"))
    }

    /// Если нужна инверсия (тёмная тема без встроенной поддержки),
    /// вставляет `<style>` с filter:invert в `<head>` перед загрузкой.
    private func htmlWithDarkModeIfNeeded(_ html: String, hasDarkModeSupport: Bool) -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard isDark, !hasDarkModeSupport else { return html }

        let css = """
        <style id="mailai-dark-mode-css">
        html { filter: invert(1) hue-rotate(180deg); }
        img, video, picture { filter: invert(1) hue-rotate(180deg); }
        </style>
        """
        // Вставляем перед </head>, либо после <head>, либо в начало
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: range, with: "\(css)\n</head>")
        }
        if let range = html.range(of: #"<head[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(html[range])
            return html.replacingCharacters(in: range, with: "\(tag)\n\(css)")
        }
        return css + html
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let isLinkActivated = navigationAction.navigationType == .linkActivated

        switch scheme {
        case "about", "cid", "data":
            // about:blank — начальная загрузка;
            // cid: — встроенные вложения (обрабатываются MailCIDSchemeHandler);
            // data: — встроенные изображения в base64.
            // Переход по ссылке на data: запрещён.
            decisionHandler(isLinkActivated ? .cancel : .allow)
        case "https":
            if isLinkActivated {
                // Внешние ссылки открываем в браузере, не в WKWebView
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                // Субресурсы (img src, css) — разрешены, блокировка внешних изображений
                // управляется через CSP в HTMLPreprocessor
                decisionHandler(.allow)
            }
        case "http", "javascript", "file":
            // http: небезопасен; javascript: запрещён явно; file: запрещён в sandbox
            if isLinkActivated && scheme == "http" {
                // Попытаемся открыть http-ссылку в браузере (пусть браузер решает)
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }
}
