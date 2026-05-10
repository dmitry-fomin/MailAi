import SwiftUI

// MARK: - Prompt Editor Tab

struct PromptEditorTab: View {
    @StateObject private var viewModel = PromptEditorViewModel()
    @State private var editingContent: String = ""

    var body: some View {
        HSplitView {
            List(viewModel.entries, selection: $viewModel.selectedID) { entry in
                Label(entry.displayName, systemImage: entry.icon)
                    .tag(entry.id)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160, idealWidth: 180)

            VStack(spacing: 0) {
                if viewModel.selectedEntry != nil {
                    TextEditor(text: $editingContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    HStack(spacing: 12) {
                        Text(statusLabel)
                            .font(.caption)
                            .foregroundStyle(isCustom ? Color.accentColor : .secondary)
                        Spacer()
                        Button("Сбросить") {
                            Task {
                                await viewModel.reset()
                                syncEditing()
                            }
                        }
                        .disabled(!isCustom)
                        Button("Сохранить") {
                            let content = editingContent
                            Task { await viewModel.save(content: content) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
                } else {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Выберите промпт для редактирования")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .frame(minWidth: 280)
        }
        .task { await viewModel.load(); syncEditing() }
        .onChange(of: viewModel.selectedID) { _, _ in syncEditing() }
        .onChange(of: viewModel.selectedEntry?.content) { _, newContent in
            if let newContent, editingContent != newContent {
                editingContent = newContent
            }
        }
    }

    private var isCustom: Bool { viewModel.selectedEntry?.isCustom ?? false }

    private var statusLabel: String {
        isCustom ? "Изменён" : "Стандартный"
    }

    private func syncEditing() {
        editingContent = viewModel.selectedEntry?.content ?? ""
    }
}
