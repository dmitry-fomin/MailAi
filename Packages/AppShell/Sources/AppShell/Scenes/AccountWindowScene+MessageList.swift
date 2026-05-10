import SwiftUI
import Core
import UI
import AI

extension AccountWindowScene {

    // MARK: - AI-5 filtered list

    struct FilteredSpec {
        let target: Importance
        let title: String
        let icon: String
    }

    func filteredSpec(for kind: SidebarItem.Kind) -> FilteredSpec {
        switch kind {
        case .smartImportant:
            return FilteredSpec(target: .important, title: "Важное", icon: "exclamationmark.circle")
        case .smartUnimportant:
            return FilteredSpec(target: .unimportant, title: "Неважно", icon: "archivebox")
        default:
            return FilteredSpec(target: .unknown, title: "", icon: "tray")
        }
    }

    @ViewBuilder
    func filteredMessageList(for kind: SidebarItem.Kind) -> some View {
        let spec = filteredSpec(for: kind)
        let filtered = session.messages.filter { $0.importance == spec.target }

        VStack(alignment: .leading, spacing: 0) {
            filteredHeader(title: spec.title, count: filtered.count)
            progressBar
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    spec.title,
                    systemImage: spec.icon,
                    description: Text("Папка пока пуста. Когда AI-классификация отметит письма, они появятся здесь.")
                )
            } else {
                List(selection: Binding(
                    get: { session.selectedMessageID },
                    set: { id in
                        session.selectedMessageID = id
                        session.open(messageID: id)
                    }
                )) {
                    ForEach(filtered) { message in
                        draggableRow(for: message)
                            .tag(message.id as Message.ID?)
                            .id(message.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func filteredHeader(title: String, count: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("\(count) писем").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Message list

    @ViewBuilder var messageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            progressBar
            Divider()
            // MailAi-3iz: пустые состояния.
            if !session.searchQuery.isEmpty && session.searchResults.isEmpty && !session.isSearching {
                ContentUnavailableView.search(text: session.searchQuery)
            } else if session.lastError != nil && session.messages.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Не удалось загрузить",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Проверьте соединение")
                    )
                    Button("Повторить") {
                        Task {
                            if let id = session.selectedMailboxID {
                                await session.loadMessages(for: id)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if session.messages.isEmpty && !session.isLoadingMessages
                        && session.lastError == nil && session.searchQuery.isEmpty {
                ContentUnavailableView(
                    "Папка пуста",
                    systemImage: "tray",
                    description: Text("Здесь появятся письма")
                )
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { session.selectedMessageID },
                        set: { id in
                            session.selectedMessageID = id
                            session.open(messageID: id)
                        }
                    )) {
                        ForEach(displayedMessages) { message in
                            draggableRow(for: message)
                                .tag(message.id as Message.ID?)
                                .id(message.id)
                        }
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1, proxy: proxy)
                        return .handled
                    }
                    .onChange(of: session.selectedMessageID) { _, newID in
                        guard let id = newID else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// AI-5: progress-bar переиспользуется в обычном и filtered-режиме.
    @ViewBuilder
    var progressBar: some View {
        ClassificationProgressBar(
            isActive: classificationProgress.isActive,
            processed: classificationProgress.processed,
            total: classificationProgress.total
        )
    }

    func moveSelection(by delta: Int, proxy: ScrollViewProxy) {
        let list = displayedMessages
        guard !list.isEmpty else { return }
        let ids = list.map(\.id)
        let currentIndex: Int
        if let selected = session.selectedMessageID,
           let idx = ids.firstIndex(of: selected) {
            currentIndex = idx
        } else {
            currentIndex = delta > 0 ? -1 : ids.count
        }
        let nextIndex = max(0, min(ids.count - 1, currentIndex + delta))
        guard nextIndex != currentIndex else { return }
        let nextID = ids[nextIndex]
        session.selectedMessageID = nextID
        session.open(messageID: nextID)
        proxy.scrollTo(nextID, anchor: .center)
    }

    @ViewBuilder var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedMailboxName)
                        .font(.headline)
                    Text("\(displayedMessages.count) писем\(session.isSearching ? " · ищем…" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $showOnlyUnread) {
                    Image(systemName: "envelope.badge")
                        .help("Только непрочитанные")
                }
                .toggleStyle(.button)
                .tint(showOnlyUnread ? .accentColor : nil)
                .buttonStyle(.borderless)
            }
            if session.searchService != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Поиск (from:alice has:attachment is:unread …)",
                              text: Binding(
                                get: { session.searchQuery },
                                set: { session.searchQuery = $0 }
                              ))
                    .textFieldStyle(.roundedBorder)
                    if !session.searchQuery.isEmpty {
                        Button {
                            session.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    var displayedMessages: [Message] {
        let q = session.searchQuery.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? session.messages : session.searchResults
        return showOnlyUnread ? base.filter { !$0.flags.contains(.seen) } : base
    }

    var selectedMailboxName: String {
        guard let id = session.selectedMailboxID,
              let mailbox = session.mailboxes.first(where: { $0.id == id }) else {
            return "—"
        }
        return mailbox.name
    }

    /// AI-5: строка списка с .draggable() для drag-to-rule.
    @ViewBuilder
    func draggableRow(for message: Message) -> some View {
        MessageRowView(
            message: message,
            moveTargets: session.mailboxes.filter { $0.id != session.selectedMailboxID },
            onMove: { targetID in Task { await session.perform(.moveToMailbox(targetID)) } }
        )
        .draggable(DraggableMessage(message: message))
    }
}
