import Foundation
import Core

/// Переиспользуемые SwiftUI-компоненты (MessageRowView, MailboxRowView,
/// ReaderHeaderView и т.д.) появятся в фазе A — см. IMPLEMENTATION_PLAN.md.
///
/// На этапе 0.2 пакет содержит только маркёр версии API, чтобы
/// AppShell мог подключаться и пайплайн сборки проходил зелёным.
public enum UIPackage {
    public static let apiVersion: Int = 1
}

/// Утилита форматирования даты для списка писем: «18:05» / «Вчера» / «28 авг».
/// Вынесена в Core-независимый слой UI, потому что формат завязан на locale,
/// а не на доменные модели.
public enum MessageDateFormatter {
    public static func short(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDate(date, inSameDayAs: now) {
            let f = DateFormatter()
            f.locale = locale
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Вчера"
        }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date)
    }
}
