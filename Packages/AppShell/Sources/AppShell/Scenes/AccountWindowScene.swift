import SwiftUI
import Core
import UI

public struct AccountWindowScene: View {
    @ObservedObject var session: AccountSessionModel
    @StateObject private var sidebar: SidebarViewModel

    public init(session: AccountSessionModel) {
        self.session = session
        _sidebar = StateObject(wrappedValue: SidebarViewModel(account: session.account))
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: sidebar) { item in
                handleSelection(item)
            }
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
            await sidebar.rebuild(with: session.mailboxes)
            if let mailboxID = sidebar.mailboxID(for: sidebar.selectedItemID) {
                session.selectedMailboxID = mailboxID
                await session.loadMessages(for: mailboxID)
            }
        }
        .onChange(of: session.mailboxes) { _, newValue in
            Task { await sidebar.rebuild(with: newValue) }
        }
        .onDisappear {
            session.closeSession()
        }
    }

    private func handleSelection(_ item: SidebarItem) {
        if case .mailbox(let mailboxID, _) = item.kind {
            session.selectedMailboxID = mailboxID
            Task { await session.loadMessages(for: mailboxID) }
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
        MessageRowView(message: message)
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
