import AppKit
import QuickLookUI
import Foundation

/// Создаёт временный файл, записывает данные вложения и открывает QLPreviewPanel.
/// Временный файл удаляется при вызове `cleanup()` или в `deinit`.
@MainActor
public final class AttachmentQuickLook: NSObject {
    private var tempURL: URL?
    private var previewHelper: QLPreviewHelper?

    public override init() {}

    /// Записывает данные во временный файл и открывает Quick Look Panel.
    public func preview(data: Data, filename: String, in window: NSWindow?) {
        // Очистить предыдущий временный файл если был
        if let existing = tempURL {
            try? FileManager.default.removeItem(at: existing)
            tempURL = nil
        }

        // Создать temp директорию: <NSTemporaryDirectory>/<UUID>/<filename>
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return
        }

        let fileURL = tempDir.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            return
        }

        tempURL = fileURL

        // Настроить helper и открыть QLPreviewPanel
        let helper = QLPreviewHelper(url: fileURL)
        previewHelper = helper

        let panel = QLPreviewPanel.shared()!
        panel.dataSource = helper
        panel.delegate = helper
        panel.reloadData()

        if let window {
            panel.makeKeyAndOrderFront(window)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Удаляет временный файл вручную (например, при закрытии письма).
    public func cleanup() {
        previewHelper = nil
        guard let url = tempURL else { return }
        // Удалить временную директорию целиком
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        tempURL = nil
    }

    deinit {
        // Синхронная очистка
        if let url = tempURL {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - QL Helper

/// Вспомогательный класс — dataSource + delegate для QLPreviewPanel.
private final class QLPreviewHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL
    }
}
