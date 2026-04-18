import SwiftUI
import Core

/// Строка списка писем: from / time / subject / preview с индикаторами
/// непрочитанности, ответа и вложения. Виртуализация обеспечивается
/// `List`-контейнером на стороне вызывающего кода (см. `AccountWindowScene`).
///
/// На 10k+ писем SwiftUI-`List` держит плавный скролл; если появится просадка,
/// план из docs/UI.md — заменить на `NSTableView` через `NSViewRepresentable`.
public struct MessageRowView: View {
    public let message: Message
    public let now: Date

    public init(message: Message, now: Date = Date()) {
        self.message = message
        self.now = now
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            unreadDot
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(senderLabel)
                        .font(.subheadline.weight(isUnread ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(MessageDateFormatter.short(message.date, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                HStack(spacing: 4) {
                    if isReply {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Ответ")
                    }
                    Text(message.subject)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Вложение")
                    }
                }

                if let preview = message.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Derived

    private var isUnread: Bool { !message.flags.contains(.seen) }
    private var isReply: Bool { message.flags.contains(.answered) || message.subject.lowercased().hasPrefix("re:") }
    private var hasAttachment: Bool { message.flags.contains(.hasAttachment) }

    private var senderLabel: String {
        if let from = message.from {
            if let name = from.name, !name.isEmpty { return name }
            return from.address
        }
        return "—"
    }

    @ViewBuilder private var unreadDot: some View {
        if isUnread {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Непрочитано")
        } else {
            Color.clear.frame(width: 8, height: 8)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if isUnread { parts.append("Непрочитано") }
        parts.append("От \(senderLabel)")
        parts.append("Тема \(message.subject)")
        if hasAttachment { parts.append("есть вложение") }
        if isReply { parts.append("ответ") }
        return parts.joined(separator: ", ")
    }
}
