import SwiftUI
import Core

/// Строка списка писем: from / time / subject / preview с индикаторами
/// непрочитанности, ответа и вложения. Виртуализация обеспечивается
/// `List`-контейнером на стороне вызывающего кода (см. `AccountWindowScene`).
///
/// На 10k+ писем SwiftUI-`List` держит плавный скролл; если появится просадка,
/// план из docs/UI.md — заменить на `NSTableView` через `NSViewRepresentable`.
///
/// AI-превью (MailAi-mon): если `aiSnippet` задан — показывается вместо preview.
/// Если `aiSnippetLoading` == true — показывается placeholder «...».
public struct MessageRowView: View {
    public let message: Message
    public let now: Date
    /// Список папок, отображаемых в контекстном меню «Переместить в…».
    /// Пустой массив по умолчанию — меню не показывается.
    public var moveTargets: [Mailbox]
    /// Callback, вызываемый при выборе целевой папки в контекстном меню.
    public var onMove: ((Mailbox.ID) -> Void)?
    /// MailAi-tq1r: true — показывать VIP-звёздочку рядом с именем отправителя.
    public var isVIP: Bool
    /// AI-сниппет (MailAi-mon). nil — показывается стандартный message.preview.
    public var aiSnippet: String?
    /// true — идёт асинхронная генерация AI-сниппета, показываем placeholder «...».
    public var aiSnippetLoading: Bool

    public init(
        message: Message,
        now: Date = Date(),
        moveTargets: [Mailbox] = [],
        onMove: ((Mailbox.ID) -> Void)? = nil,
        isVIP: Bool = false,
        aiSnippet: String? = nil,
        aiSnippetLoading: Bool = false
    ) {
        self.message = message
        self.now = now
        self.moveTargets = moveTargets
        self.onMove = onMove
        self.isVIP = isVIP
        self.aiSnippet = aiSnippet
        self.aiSnippetLoading = aiSnippetLoading
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
                    // MailAi-tq1r: VIP star badge
                    if isVIP {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("VIP отправитель")
                    }
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

                previewLine
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            if !moveTargets.isEmpty {
                Menu("Переместить в…") {
                    ForEach(moveTargets) { mailbox in
                        Button(mailbox.name) { onMove?(mailbox.id) }
                    }
                }
            }
        }
    }

    // MARK: - Preview Line

    /// Строка превью: AI-сниппет (если есть) > loading placeholder > стандартный preview.
    @ViewBuilder private var previewLine: some View {
        if aiSnippetLoading {
            Text("...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
                .lineLimit(1)
                .accessibilityLabel("AI-превью загружается")
        } else if let snippet = aiSnippet, !snippet.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)
            }
            .accessibilityLabel("AI-превью: \(snippet)")
        } else if let preview = message.preview, !preview.isEmpty {
            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
        if isVIP { parts.append("VIP") }
        parts.append("От \(senderLabel)")
        parts.append("Тема \(message.subject)")
        if hasAttachment { parts.append("есть вложение") }
        if isReply { parts.append("ответ") }
        return parts.joined(separator: ", ")
    }
}
