// Packages/UI/Sources/UI/Reader/MessageWebView.swift
import SwiftUI
import WebKit
import AppKit

/// SwiftUI-обёртка над WKWebView для отображения HTML-письма.
public struct MessageWebView: NSViewRepresentable {
    public let processedEmail: ProcessedEmail
    public let messageID: String
    public let cacheManager: CacheManager

    public init(processedEmail: ProcessedEmail, messageID: String, cacheManager: CacheManager) {
        self.processedEmail = processedEmail
        self.messageID = messageID
        self.cacheManager = cacheManager
    }

    public func makeNSView(context: Context) -> WKWebView {
        let handler = MailCIDSchemeHandler { msgID, contentID in
            await cacheManager.readAttachment(messageID: msgID, contentID: contentID)
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(handler, forURLScheme: "cid")
        config.preferences.setValue(false, forKey: "allowFileAccessFromFileURLs")

        let controller = MessageWebViewController(
            configuration: config,
            cidHandler: handler,
            processedEmail: processedEmail,
            messageID: messageID
        )
        context.coordinator.viewController = controller
        return controller.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let vc = context.coordinator.viewController else { return }
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

/// NSViewController — WKNavigationDelegate + тёмная тема.
public final class MessageWebViewController: NSObject, WKNavigationDelegate, @unchecked Sendable {
    public let webView: WKWebView
    private let cidHandler: MailCIDSchemeHandler
    public private(set) var currentMessageID: String = ""

    public init(
        configuration: WKWebViewConfiguration,
        cidHandler: MailCIDSchemeHandler,
        processedEmail: ProcessedEmail,
        messageID: String
    ) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.cidHandler = cidHandler
        super.init()
        self.webView.navigationDelegate = self
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
        cidHandler.setCurrentMessage(messageID)
        webView.loadHTMLString("", baseURL: nil)
        injectDarkModeCSS(hasDarkModeSupport: processedEmail.hasDarkModeSupport)
        webView.loadHTMLString(processedEmail.html, baseURL: URL(string: "about:blank"))
    }

    // MARK: - Dark mode

    @objc private func appearanceDidChange() {
        injectDarkModeCSS(hasDarkModeSupport: nil)
    }

    private func injectDarkModeCSS(hasDarkModeSupport: Bool?) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard isDark else {
            webView.evaluateJavaScript("document.getElementById('mailai-dark-mode-css')?.remove()")
            return
        }
        guard !(hasDarkModeSupport ?? false) else { return }

        let css = """
        html { filter: invert(1) hue-rotate(180deg); }
        img, video, picture { filter: invert(1) hue-rotate(180deg); }
        """
        let js = """
        (function(){
          var el = document.getElementById('mailai-dark-mode-css');
          if (!el) { el = document.createElement('style'); el.id = 'mailai-dark-mode-css'; document.head.appendChild(el); }
          el.textContent = '\(css.replacingOccurrences(of: "\n", with: " "))';
        })();
        """
        webView.evaluateJavaScript(js)
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "about":
            decisionHandler(.allow)
        case "https":
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow) // subresource
            }
        case "http", "javascript", "file":
            decisionHandler(.cancel)
        case "data":
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow) // data:image/* как subresource
            }
        default:
            decisionHandler(.cancel)
        }
    }
}
