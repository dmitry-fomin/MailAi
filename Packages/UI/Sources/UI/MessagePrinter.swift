import AppKit
import WebKit
import Core

// MARK: - MessagePrinter

/// Печатает HTML-содержимое письма через стандартный macOS Print dialog.
///
/// Использует `WKWebView` для рендеринга HTML с print-специфичным CSS,
/// затем открывает `NSPrintOperation` с диалогом.
///
/// Тело письма загружается только в памяти — не сохраняется на диск.
@MainActor
public final class MessagePrinter {

    public static let shared = MessagePrinter()

    private init() {}

    // MARK: - Public API

    /// Открывает диалог печати для письма.
    ///
    /// - Parameters:
    ///   - message: Метаданные письма (заголовки).
    ///   - htmlBody: HTML-содержимое тела письма. Если `nil` — печатает только заголовки.
    ///   - attachmentNames: Имена вложений для отображения в печатной версии.
    public func print(
        message: Message,
        htmlBody: String?,
        attachmentNames: [String] = []
    ) {
        let printHTML = buildPrintHTML(message: message, htmlBody: htmlBody, attachmentNames: attachmentNames)
        PrintWebView.present(html: printHTML)
    }

    // MARK: - HTML Builder

    private func buildPrintHTML(
        message: Message,
        htmlBody: String?,
        attachmentNames: [String]
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        dateFormatter.locale = Locale.current

        let dateString = dateFormatter.string(from: message.date)
        let subject = escapeHTML(message.subject.isEmpty ? "(Без темы)" : message.subject)
        let from = escapeHTML(formatAddress(message.from))
        let toList = message.to.map { escapeHTML(formatAddress($0)) }.joined(separator: ", ")

        var headersHTML = """
        <div class="header">
            <table>
                <tr><th>От:</th><td>\(from)</td></tr>
                <tr><th>Кому:</th><td>\(toList.isEmpty ? "&mdash;" : toList)</td></tr>
        """

        if !message.cc.isEmpty {
            let ccList = message.cc.map { escapeHTML(formatAddress($0)) }.joined(separator: ", ")
            headersHTML += "<tr><th>Копия:</th><td>\(ccList)</td></tr>"
        }

        headersHTML += """
                <tr><th>Тема:</th><td><strong>\(subject)</strong></td></tr>
                <tr><th>Дата:</th><td>\(escapeHTML(dateString))</td></tr>
            </table>
        </div>
        <hr class="header-separator">
        """

        var attachmentsHTML = ""
        if !attachmentNames.isEmpty {
            let items = attachmentNames.map { "<li>\(escapeHTML($0))</li>" }.joined()
            attachmentsHTML = """
            <hr class="attachments-separator">
            <div class="attachments">
                <strong>Вложения:</strong>
                <ul>\(items)</ul>
            </div>
            """
        }

        let bodyHTML = htmlBody ?? "<p><em>(Тело письма недоступно)</em></p>"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>\(subject)</title>
            <style>
                \(printCSS)
            </style>
        </head>
        <body>
            \(headersHTML)
            <div class="body">
                \(bodyHTML)
            </div>
            \(attachmentsHTML)
        </body>
        </html>
        """
    }

    // MARK: - Print CSS

    private var printCSS: String {
        """
        * {
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, 'Helvetica Neue', Arial, sans-serif;
            font-size: 11pt;
            color: #000;
            background: #fff;
            margin: 0;
            padding: 0;
        }

        .header {
            margin-bottom: 8pt;
        }

        .header table {
            border-collapse: collapse;
            width: 100%;
        }

        .header th {
            text-align: right;
            padding: 2pt 8pt 2pt 0;
            color: #555;
            font-weight: normal;
            white-space: nowrap;
            width: 60pt;
            vertical-align: top;
        }

        .header td {
            padding: 2pt 0;
            color: #000;
        }

        hr.header-separator,
        hr.attachments-separator {
            border: none;
            border-top: 1px solid #ccc;
            margin: 8pt 0;
        }

        .body {
            margin: 8pt 0;
            line-height: 1.5;
        }

        .body img {
            max-width: 100%;
            height: auto;
        }

        .body blockquote {
            border-left: 3px solid #ccc;
            margin-left: 12pt;
            padding-left: 8pt;
            color: #555;
        }

        .attachments {
            color: #555;
            font-size: 9pt;
        }

        .attachments ul {
            margin: 4pt 0 0 16pt;
            padding: 0;
        }

        @media print {
            body {
                margin: 0;
            }

            .no-print {
                display: none !important;
            }

            a[href]::after {
                content: " (" attr(href) ")";
                font-size: 8pt;
                color: #666;
            }

            /* Не разрываем заголовок между страницами */
            .header {
                page-break-inside: avoid;
            }
        }
        """
    }

    // MARK: - Helpers

    private func formatAddress(_ address: MailAddress?) -> String {
        guard let address else { return "" }
        if let name = address.name, !name.isEmpty {
            return "\(name) <\(address.address)>"
        }
        return address.address
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - PrintWebView

/// Вспомогательный `WKWebView`, который загружает HTML и открывает диалог печати.
///
/// Живёт ровно столько, сколько нужно для печати — удерживается сам через `retain`
/// до завершения `print(with:)`.
@MainActor
private final class PrintWebView: NSObject, WKNavigationDelegate {

    private let webView: WKWebView
    private let html: String
    private var navigationDelegate: PrintWebView?

    private init(html: String) {
        self.html = html

        let config = WKWebViewConfiguration()
        // Не кешируем — тело письма только в памяти.
        config.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: config)

        super.init()
        self.webView.navigationDelegate = self
    }

    /// Создаёт `PrintWebView`, загружает HTML и открывает Print dialog.
    static func present(html: String) {
        let printView = PrintWebView(html: html)
        // Удерживаем объект через static-ссылку пока идёт печать.
        printView.navigationDelegate = printView
        printView.webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.isVerticallyCentered = false

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()

        // Освобождаем self после печати.
        navigationDelegate = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        // При ошибке загрузки просто освобождаем.
        navigationDelegate = nil
    }
}
