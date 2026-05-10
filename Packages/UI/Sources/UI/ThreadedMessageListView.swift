import SwiftUI
import Core

// MARK: - ThreadGroup

/// Группа писем одного треда для отображения в `ThreadedMessageListView`.
/// Письма упорядочены хронологически (по `date`).
struct ThreadGroup: Identifiable {
    let id: MessageThread.ID
    let subject: String
    let messages: [Message]  // в хронологическом порядке

    /// Дата последнего письма в треде.
    var lastDate: Date { messages.last?.date ?? .distantPast }

    /// Количество непрочитанных писем в треде.
    var unreadCount: Int { messages.filter { !$0.flags.contains(.seen) }.count }
}

// MARK: - ThreadGrouper

/// Утилита для группировки плоского списка `[Message]` в `[ThreadGroup]`
/// по `threadID`. Письма без `threadID` образуют псевдо-тред из одного письма
/// с ключом на основе `message.id`.
enum ThreadGrouper {
    static func group(_ messages: [Message]) -> [ThreadGroup] {
        var buckets: [MessageThread.ID: [Message]] = [:]

        for message in messages {
            let key = message.threadID ?? MessageThread.ID(message.id.rawValue)
            buckets[key, default: []].append(message)
        }

        return buckets.map { key, msgs -> ThreadGroup in
            let sorted = msgs.sorted { $0.date < $1.date }
            let subject = sorted.last?.subject ?? sorted.first?.subject ?? ""
            return ThreadGroup(id: key, subject: subject, messages: sorted)
        }
        // Показываем самые свежие треды первыми.
        .sorted { $0.lastDate > $1.lastDate }
    }
}

// MARK: - ThreadedMessageListView

/// Список писем, сгруппированный по тредам (`threadID` / `references`).
///
/// Каждый тред отображается как раскрываемая секция:
/// - заголовок: тема, счётчик непрочитанных, дата последнего письма;
/// - тело: хронологически упорядоченные `MessageRowView`.
///
/// Треды без связанных писем не отображаются. Одиночные письма (без `threadID`)
/// показываются как мини-тред из одного элемента — с теми же отступами.
///
/// Пример использования:
/// ```swift
/// ThreadedMessageListView(
///     messages: session.messages,
///     selection: $session.selectedMessageID,
///     onOpen: { id in session.open(messageID: id) }
/// )
/// ```
public struct ThreadedMessageListView: View {

    // MARK: - Input

    public let messages: [Message]
    @Binding public var selection: Message.ID?
    public var onOpen: ((Message.ID) -> Void)?

    // MARK: - State

    /// Множество ID тредов, у которых развёрнут список писем.
    @State private var expandedThreads: Set<MessageThread.ID> = []

    // MARK: - Init

    public init(
        messages: [Message],
        selection: Binding<Message.ID?>,
        onOpen: ((Message.ID) -> Void)? = nil
    ) {
        self.messages = messages
        self._selection = selection
        self.onOpen = onOpen
    }

    // MARK: - Derived

    private var threads: [ThreadGroup] {
        ThreadGrouper.group(messages)
    }

    // MARK: - Body

    public var body: some View {
        List(selection: $selection) {
            ForEach(threads) { thread in
                threadSection(thread)
            }
        }
        .listStyle(.plain)
        .onAppear {
            // Авто-раскрываем тред с выбранным письмом, если есть.
            if let sel = selection,
               let thread = threads.first(where: { $0.messages.contains(where: { $0.id == sel }) }) {
                expandedThreads.insert(thread.id)
            }
        }
        .onChange(of: selection) { _, newSel in
            guard let sel = newSel else { return }
            if let thread = threads.first(where: { $0.messages.contains(where: { $0.id == sel }) }) {
                expandedThreads.insert(thread.id)
            }
        }
    }

    // MARK: - Thread Section

    @ViewBuilder
    private func threadSection(_ thread: ThreadGroup) -> some View {
        let isExpanded = expandedThreads.contains(thread.id)

        Section {
            if isExpanded {
                ForEach(thread.messages) { message in
                    MessageRowView(message: message)
                        .tag(message.id as Message.ID?)
                        .id(message.id)
                        .padding(.leading, 16) // визуальный отступ вложенности
                        .onTapGesture {
                            selection = message.id
                            onOpen?(message.id)
                        }
                }
            }
        } header: {
            ThreadHeaderRow(
                thread: thread,
                isExpanded: isExpanded,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedThreads.contains(thread.id) {
                            expandedThreads.remove(thread.id)
                        } else {
                            expandedThreads.insert(thread.id)
                        }
                    }
                    // Одиночное письмо — открываем сразу при тапе на заголовок.
                    if thread.messages.count == 1, let msg = thread.messages.first {
                        selection = msg.id
                        onOpen?(msg.id)
                    }
                }
            )
        }
        .collapsible(false) // управление раскрытием делаем сами
    }
}

// MARK: - ThreadHeaderRow

/// Строка-заголовок треда: тема, счётчик писем, дата, индикатор непрочитанных.
private struct ThreadHeaderRow: View {
    let thread: ThreadGroup
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Индикатор непрочитанных.
                if thread.unreadCount > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                } else {
                    Color.clear.frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.subject.isEmpty ? "(без темы)" : thread.subject)
                        .font(.subheadline.weight(thread.unreadCount > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Text("\(thread.messages.count) писем")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(MessageDateFormatter.short(thread.lastDate, now: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if thread.unreadCount > 0 {
                        Text("\(thread.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                    }
                }

                // Chevron раскрытия/скрытия (скрыт для одиночных писем).
                if thread.messages.count > 1 {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [thread.subject.isEmpty ? "Без темы" : thread.subject]
        parts.append("\(thread.messages.count) писем")
        if thread.unreadCount > 0 { parts.append("\(thread.unreadCount) непрочитанных") }
        parts.append(isExpanded ? "развёрнут" : "свёрнут")
        return parts.joined(separator: ", ")
    }
}
