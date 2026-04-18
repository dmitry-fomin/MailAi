import SwiftUI

/// A9: утилита для ручной проверки UI в обеих темах и при разных размерах
/// шрифта. Используется в Xcode-превью, смысла в рантайме не несёт.
///
/// Правила проекта (см. Scripts/lint-theming.sh):
/// - Только семантические цвета: `.primary`, `.secondary`, `.accentColor`,
///   `Color.clear`, `Color(nsColor:)` от системных NSColor. RGB-литералы
///   и hex-цвета запрещены.
/// - Только relative-шрифты: `.body`, `.caption`, `.title2` и т.п. Никаких
///   `.system(size:)` — они ломают Dynamic Type.
public struct ThemeAuditContainer<Content: View>: View {
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .environment(\.colorScheme, .light)
            Divider()
            content
                .environment(\.colorScheme, .dark)
        }
    }
}

/// Перебор всех DynamicTypeSize значений — полезно в превью, чтобы быстро
/// увидеть обрезание или наезды при увеличенном системном шрифте.
public struct DynamicTypeSweep<Content: View>: View {
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(DynamicTypeSize.allCases, id: \.self) { size in
                content
                    .dynamicTypeSize(size)
                    .border(.quaternary)
            }
        }
    }
}
