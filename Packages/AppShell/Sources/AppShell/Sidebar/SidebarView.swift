import SwiftUI
import Core

public struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    var onSelect: (SidebarItem) -> Void
    /// AI-5: drop сообщений на «Неважно» / «Важное». Получает массив
    /// `DraggableMessage` и kind целевого item'а.
    var onDropMessages: ((SidebarItem.Kind, [DraggableMessage]) -> Void)?

    public init(
        viewModel: SidebarViewModel,
        onSelect: @escaping (SidebarItem) -> Void,
        onDropMessages: ((SidebarItem.Kind, [DraggableMessage]) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onSelect = onSelect
        self.onDropMessages = onDropMessages
    }

    public var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedItemID },
            set: { newValue in
                viewModel.selectedItemID = newValue
                if let newValue, let item = viewModel.item(for: newValue) {
                    onSelect(item)
                }
            }
        )) {
            ForEach(viewModel.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        rowView(for: item)
                            .tag(item.id as SidebarItem.ID?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func rowView(for item: SidebarItem) -> some View {
        let row = SidebarRow(item: item)
        switch item.kind {
        case .smartUnimportant, .smartImportant:
            row
                .dropDestination(for: DraggableMessage.self) { dropped, _ in
                    guard !dropped.isEmpty else { return false }
                    onDropMessages?(item.kind, dropped)
                    return true
                }
        default:
            row
        }
    }
}

struct SidebarRow: View {
    let item: SidebarItem

    var body: some View {
        Label {
            HStack {
                Text(item.title)
                Spacer(minLength: 8)
                if item.unreadCount > 0 {
                    Text("\(item.unreadCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
        }
    }
}
