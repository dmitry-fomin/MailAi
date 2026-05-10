import SwiftUI
import Core

/// Шапка ридера: аватар-заглушка, отправитель, список получателей, дата.
/// Имена и адреса — только из `Message`; никакой сетевой догрузки аватаров.
///
/// По умолчанию — collapsed: показывает только From, Subject, Date.
/// По клику — expanded: все поля From/To/CC/Date.
public struct ReaderHeaderView: View {
    public let message: Message
    public let now: Date

    @State private var isExpanded: Bool = false

    public init(message: Message, now: Date = Date()) {
        self.message = message
        self.now = now
    }

    public var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
            HStack(alignment: .top, spacing: 12) {
                avatar
                    .accessibilityHidden(true) // Аватар-заглушка не несёт информации

                VStack(alignment: .leading, spacing: 4) {
                    // Subject — всегда виден
                    Text(message.subject)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    if isExpanded {
                        expandedFields
                    } else {
                        collapsedFields
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(MessageDateFormatter.short(message.date, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // MailAi-eyb1: VoiceOver accessibility для заголовка письма
        .accessibilityLabel(headerAccessibilityLabel)
        .accessibilityHint(isExpanded ? "Нажмите, чтобы свернуть детали" : "Нажмите, чтобы развернуть детали")
        .accessibilityValue(isExpanded ? "Развёрнут" : "Свёрнут")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Collapsed state

    @ViewBuilder
    private var collapsedFields: some View {
        HStack(spacing: 4) {
            Text(fromLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            if let address = message.from?.address, message.from?.name != nil {
                Text("<\(address)>")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Expanded state

    @ViewBuilder
    private var expandedFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow(label: "От", value: fullFromLabel)

            if !message.to.isEmpty {
                headerRow(label: "Кому", value: recipients(message.to))
            }

            if !message.cc.isEmpty {
                headerRow(label: "Копия", value: recipients(message.cc))
            }

            headerRow(label: "Дата", value: longDate)
        }
    }

    @ViewBuilder
    private func headerRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private var fromLabel: String {
        guard let from = message.from else { return "—" }
        return from.name ?? from.address
    }

    private var fullFromLabel: String {
        guard let from = message.from else { return "—" }
        if let name = from.name, !name.isEmpty {
            return "\(name) <\(from.address)>"
        }
        return from.address
    }

    private func recipients(_ list: [MailAddress]) -> String {
        list.map { addr in
            if let name = addr.name, !name.isEmpty {
                return "\(name) <\(addr.address)>"
            }
            return addr.address
        }
        .joined(separator: ", ")
    }

    private var longDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter.string(from: message.date)
    }

    // MARK: - Avatar

    @ViewBuilder private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))
            Text(initials)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(width: 40, height: 40)
    }

    /// Полная accessibility метка для кнопки-заголовка письма.
    private var headerAccessibilityLabel: String {
        var parts: [String] = []
        let subject = message.subject.isEmpty ? "Без темы" : message.subject
        parts.append("Тема: \(subject)")
        parts.append("От: \(fullFromLabel)")
        if !message.to.isEmpty {
            parts.append("Кому: \(recipients(message.to))")
        }
        parts.append("Дата: \(longDate)")
        return parts.joined(separator: ". ")
    }

    private var initials: String {
        let source = message.from?.name ?? message.from?.address ?? "?"
        let parts = source.split(whereSeparator: { !$0.isLetter })
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}
