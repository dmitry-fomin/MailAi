import SwiftUI
import Core

public struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    var onSelect: (SidebarItem) -> Void

    public init(
        viewModel: SidebarViewModel,
        onSelect: @escaping (SidebarItem) -> Void
    ) {
        self.viewModel = viewModel
        self.onSelect = onSelect
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
                        SidebarRow(item: item)
                            .tag(item.id as SidebarItem.ID?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
