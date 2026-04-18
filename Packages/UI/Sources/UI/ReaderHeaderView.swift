import SwiftUI
import Core

/// Шапка ридера: аватар-заглушка, отправитель, список получателей, дата.
/// Имена и адреса — только из `Message`; никакой сетевой догрузки аватаров.
public struct ReaderHeaderView: View {
    public let message: Message
    public let now: Date

    public init(message: Message, now: Date = Date()) {
        self.message = message
        self.now = now
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                Text(message.subject)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(fromLabel)
                        .font(.subheadline.weight(.medium))
                    if let address = message.from?.address, message.from?.name != nil {
                        Text("<\(address)>")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !message.to.isEmpty {
                    Text("Кому: \(recipients(message.to))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !message.cc.isEmpty {
                    Text("Копия: \(recipients(message.cc))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(MessageDateFormatter.short(message.date, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var fromLabel: String {
        guard let from = message.from else { return "—" }
        return from.name ?? from.address
    }

    private func recipients(_ list: [MailAddress]) -> String {
        list.map { $0.name ?? $0.address }.joined(separator: ", ")
    }

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

    private var initials: String {
        let source = message.from?.name ?? message.from?.address ?? "?"
        let parts = source.split(whereSeparator: { !$0.isLetter })
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}
