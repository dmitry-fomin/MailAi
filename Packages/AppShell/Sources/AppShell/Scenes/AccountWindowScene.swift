import SwiftUI
import Core
import UI

/// Пустой каркас 3-колоночного окна-аккаунта. Реальные `UI`-компоненты
/// (MessageRowView, MailboxRowView, ReaderHeaderView) появятся в A3–A5.
public struct AccountWindowScene: View {
    @ObservedObject var session: AccountSessionModel

    public init(session: AccountSessionModel) {
        self.session = session
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 220)
        } content: {
            messageList
                .frame(minWidth: 320)
        } detail: {
            reader
                .frame(minWidth: 480)
        }
        .navigationTitle(session.account.email)
        .task {
            await session.loadMailboxes()
        }
        .onDisappear {
            session.closeSession()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder private var sidebar: some View {
        List(selection: Binding(
            get: { session.selectedMailboxID },
            set: { id in
                session.selectedMailboxID = id
                if let id { Task { await session.loadMessages(for: id) } }
            }
        )) {
            Section("Избранное") {
                Text("Флажки")
                Text("Черновики")
            }
            Section("Отфильтрованные") {
                Label("Важное", systemImage: "exclamationmark.circle")
                    .badge(0)
                Label("Неважно", systemImage: "archivebox")
                    .badge(0)
            }
            Section(session.account.email) {
                ForEach(session.mailboxes) { mailbox in
                    HStack {
                        Label(mailbox.name, systemImage: icon(for: mailbox.role))
                        Spacer()
                        if mailbox.unreadCount > 0 {
                            Text("\(mailbox.unreadCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .tag(mailbox.id as Mailbox.ID?)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func icon(for role: Mailbox.Role) -> String {
        switch role {
        case .inbox:   return "tray.and.arrow.down"
        case .sent:    return "paperplane"
        case .drafts:  return "pencil"
        case .archive: return "archivebox"
        case .trash:   return "trash"
        case .spam:    return "xmark.octagon"
        case .flagged: return "flag"
        case .custom:  return "folder"
        }
    }

    // MARK: - Message list

    @ViewBuilder private var messageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Зарезервированный слот под прогресс-бар фоновой синхронизации
            // (см. критерии приёмки SPECIFICATION.md).
            Color.clear.frame(height: 0)
            Divider()
            List(selection: Binding(
                get: { session.selectedMessageID },
                set: { id in
                    session.selectedMessageID = id
                    session.open(messageID: id)
                }
            )) {
                ForEach(session.messages) { message in
                    row(for: message)
                        .tag(message.id as Message.ID?)
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedMailboxName)
                    .font(.headline)
                Text("\(session.messages.count) писем")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectedMailboxName: String {
        guard let id = session.selectedMailboxID,
              let mailbox = session.mailboxes.first(where: { $0.id == id }) else {
            return "—"
        }
        return mailbox.name
    }

    @ViewBuilder private func row(for message: Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.from?.name ?? message.from?.address ?? "—")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(MessageDateFormatter.short(message.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.subject)
                .lineLimit(1)
            if let preview = message.preview {
                Text(preview)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Reader

    @ViewBuilder private var reader: some View {
        if let body = session.openBody {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(selectedMessageSubject)
                            .font(.headline)
                        Text(selectedMessageFrom)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()

                Divider()

                ScrollView {
                    switch body.content {
                    case .plain(let text):
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    case .html(let html):
                        Text(html)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Выберите письмо",
                systemImage: "envelope",
                description: Text("Кликните по строке в списке, чтобы открыть содержимое.")
            )
        }
    }

    private var selectedMessageSubject: String {
        guard let id = session.selectedMessageID,
              let msg = session.messages.first(where: { $0.id == id }) else { return "—" }
        return msg.subject
    }

    private var selectedMessageFrom: String {
        guard let id = session.selectedMessageID,
              let msg = session.messages.first(where: { $0.id == id }) else { return "" }
        if let from = msg.from {
            if let name = from.name { return "\(name) <\(from.address)>" }
            return from.address
        }
        return ""
    }
}
