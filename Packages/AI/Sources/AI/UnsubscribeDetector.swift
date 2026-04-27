import Foundation
import Core

/// Определяет возможность отписки по метаданным письма.
///
/// Разбирает заголовок `List-Unsubscribe` (поле `message.listUnsubscribe`).
/// AI-фоллбек не реализован — для него нужно тело письма, которое метаданные
/// не содержат.
public actor UnsubscribeDetector {
    public init() {}

    /// Анализирует `message.listUnsubscribe` и возвращает `UnsubscribeInfo`.
    /// Если поле nil — возвращает `.notFound`.
    public func detect(message: Message) -> UnsubscribeInfo {
        guard let raw = message.listUnsubscribe, !raw.isEmpty else {
            return UnsubscribeInfo(action: .notFound, detectedFrom: .listHeader)
        }
        let action = parse(raw: raw)
        return UnsubscribeInfo(action: action, detectedFrom: .listHeader)
    }

    // MARK: - Private

    /// Разбирает строку формата `<https://...>, <mailto:...>` или их подмножество.
    ///
    /// Порядок приоритетов:
    /// 1. Если строка содержит `List-Unsubscribe=One-Click` (RFC 8058) — `oneClickPost`.
    /// 2. Иначе если есть URL с `https:` — `browserLink`.
    /// 3. Иначе если есть `mailto:` — `mailto`.
    /// 4. Иначе — `notFound`.
    private func parse(raw: String) -> UnsubscribeAction {
        let isOneClick = raw.range(
            of: "List-Unsubscribe=One-Click",
            options: [.caseInsensitive]
        ) != nil

        // Извлекаем все значения внутри угловых скобок.
        let tokens = extractAngledTokens(from: raw)

        if isOneClick, let httpsURL = tokens.first(where: { $0.hasPrefix("https://") }),
           let url = URL(string: httpsURL) {
            return .oneClickPost(url)
        }

        if let httpsToken = tokens.first(where: { $0.hasPrefix("https://") }),
           let url = URL(string: httpsToken) {
            return .browserLink(url)
        }

        if let mailtoToken = tokens.first(where: { $0.hasPrefix("mailto:") }) {
            let address = String(mailtoToken.dropFirst("mailto:".count))
            return .mailto(address)
        }

        return .notFound
    }

    /// Извлекает подстроки, заключённые в `<…>`.
    private func extractAngledTokens(from raw: String) -> [String] {
        var result: [String] = []
        var remainder = raw[...]
        while let open = remainder.firstIndex(of: "<"),
              let close = remainder[remainder.index(after: open)...].firstIndex(of: ">") {
            let token = String(remainder[remainder.index(after: open)..<close])
            result.append(token)
            remainder = remainder[remainder.index(after: close)...]
        }
        return result
    }
}
