import SwiftUI
import Core

// MARK: - Mailbox Folder Actions (MailAi-6xac)

/// Действие управления папкой, передаваемое во внешний обработчик.
public enum MailboxAction: Sendable {
    case createFolder(parentPath: String?)
    case renameFolder(mailboxID: Mailbox.ID, currentName: String)
    case deleteFolder(mailboxID: Mailbox.ID, name: String)
}

// MARK: - SidebarView

public struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    var onSelect: (SidebarItem) -> Void
    /// AI-5: drop сообщений на «Неважно» / «Важное». Получает массив
    /// `DraggableMessage` и kind целевого item'а.
    var onDropMessages: ((SidebarItem.Kind, [DraggableMessage]) -> Void)?
    /// MailAi-6xac: обработчик действий управления папками (контекстное меню).
    /// nil — пункты контекстного меню для управления папками не показываются.
    var onMailboxAction: ((MailboxAction) -> Void)?

    public init(
        viewModel: SidebarViewModel,
        onSelect: @escaping (SidebarItem) -> Void,
        onDropMessages: ((SidebarItem.Kind, [DraggableMessage]) -> Void)? = nil,
        onMailboxAction: ((MailboxAction) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onSelect = onSelect
        self.onDropMessages = onDropMessages
        self.onMailboxAction = onMailboxAction
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
        // MailAi-6xac: sheet'ы для создания и переименования папок.
        // Вешаем на List, а не на отдельный overlay, чтобы избежать
        // конфликта с sheet'ами родительского View.
        .sheet(isPresented: $viewModel.showCreateFolderDialog) {
            CreateFolderDialog(
                parentPath: viewModel.pendingParentPath,
                onConfirm: { name in
                    viewModel.showCreateFolderDialog = false
                    viewModel.pendingFolderName = name
                    // Сигнализируем AccountWindowScene через pendingFolderName
                },
                onCancel: {
                    viewModel.showCreateFolderDialog = false
                    viewModel.pendingFolderName = nil
                }
            )
        }
        .sheet(isPresented: $viewModel.showRenameFolderDialog) {
            if let currentName = viewModel.pendingRenameCurrent {
                RenameFolderDialog(
                    currentName: currentName,
                    onConfirm: { newName in
                        viewModel.showRenameFolderDialog = false
                        viewModel.pendingFolderName = newName
                    },
                    onCancel: {
                        viewModel.showRenameFolderDialog = false
                        viewModel.pendingFolderName = nil
                    }
                )
            }
        }
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

        case .mailbox(let mailboxID, let role):
            // MailAi-6xac: контекстное меню — только если передан обработчик.
            if onMailboxAction != nil {
                row.contextMenu {
                    mailboxContextMenu(
                        mailboxID: mailboxID,
                        role: role,
                        name: item.title
                    )
                }
            } else {
                row
            }

        default:
            row
        }
    }

    @ViewBuilder
    private func mailboxContextMenu(
        mailboxID: Mailbox.ID,
        role: Mailbox.Role,
        name: String
    ) -> some View {
        // Новую дочернюю папку можно создать для любой папки.
        Button {
            let parentPath = viewModel.path(for: mailboxID)
            viewModel.beginCreateFolder(parentPath: parentPath)
        } label: {
            Label("Новая папка внутри «\(name)»", systemImage: "folder.badge.plus")
        }

        Button {
            viewModel.beginCreateFolder(parentPath: nil)
        } label: {
            Label("Новая папка в корне", systemImage: "folder.badge.plus")
        }

        // Переименование и удаление — только для кастомных папок.
        if role == .custom {
            Divider()

            Button {
                viewModel.beginRenameFolder(mailboxID: mailboxID, currentName: name)
            } label: {
                Label("Переименовать…", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onMailboxAction?(.deleteFolder(mailboxID: mailboxID, name: name))
            } label: {
                Label("Удалить «\(name)»", systemImage: "trash")
            }
        }
    }
}

// MARK: - Create / Rename dialogs

struct CreateFolderDialog: View {
    let parentPath: String?
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var folderName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новая папка")
                .font(.title3.bold())

            if let parent = parentPath {
                Text("Внутри: \(parent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("В корне ящика")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Название папки", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onConfirm(trimmed)
                }

            HStack {
                Button("Отмена", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Создать") {
                    let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onConfirm(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

struct RenameFolderDialog: View {
    let currentName: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var newName: String

    init(currentName: String, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.currentName = currentName
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _newName = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переименовать папку")
                .font(.title3.bold())

            TextField("Новое название", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != currentName else { return }
                    onConfirm(trimmed)
                }

            HStack {
                Button("Отмена", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Переименовать") {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != currentName else { return }
                    onConfirm(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    newName.trimmingCharacters(in: .whitespacesAndNewlines) == currentName
                )
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// MARK: - SidebarRow

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
