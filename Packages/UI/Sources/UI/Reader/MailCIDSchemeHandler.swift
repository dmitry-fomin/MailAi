// Packages/UI/Sources/UI/Reader/MailCIDSchemeHandler.swift
import WebKit
import Foundation

/// WKURLSchemeHandler для схемы cid:.
/// Является NSObject (WKURLSchemeHandler — @objc протокол, актор не подходит).
/// Делегирует фактический поиск данных в CacheManager через async callback.
public final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    public typealias DataProvider = (String, String) async -> (Data, String)?
    // (messageID, contentID) -> (data, mimeType)?

    private var currentMessageID: String = ""
    private let dataProvider: DataProvider

    public init(dataProvider: @escaping DataProvider) {
        self.dataProvider = dataProvider
    }

    public func setCurrentMessage(_ messageID: String) {
        currentMessageID = messageID
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // cid:image001 — host содержит contentID
        let contentID = url.host ?? url.absoluteString.dropFirst("cid:".count).description
        let msgID = currentMessageID

        Task {
            if let (data, mimeType) = await dataProvider(msgID, contentID) {
                let response = URLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Отмена: Task уже запущен, но результат будет проигнорирован
    }
}
