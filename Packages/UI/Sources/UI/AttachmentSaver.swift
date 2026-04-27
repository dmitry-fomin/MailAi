import AppKit
import Foundation

/// Показывает стандартный NSSavePanel и записывает данные вложения по выбранному пути.
/// Вызывающая сторона отвечает за то, что `data` больше не нужны после вызова.
@MainActor
public final class AttachmentSaver {
    private init() {}

    /// Открывает Save Panel и при подтверждении сохраняет `data` по указанному пути.
    public static func save(
        data: Data,
        suggestedFilename: String,
        in window: NSWindow?
    ) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }

        guard response == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
