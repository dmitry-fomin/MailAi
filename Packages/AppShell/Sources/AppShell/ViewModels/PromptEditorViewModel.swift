import Foundation
import AI

@MainActor
public final class PromptEditorViewModel: ObservableObject {
    @Published public private(set) var entries: [PromptEntry] = []
    @Published public var selectedID: String?

    private let store: PromptStore

    public init(store: PromptStore = .shared) {
        self.store = store
    }

    public var selectedEntry: PromptEntry? {
        entries.first { $0.id == selectedID }
    }

    /// Loads all prompt entries, populating content and isCustom from PromptStore.
    public func load() async {
        var loaded: [PromptEntry] = []
        for var entry in PromptEntry.allEntries {
            let content = (try? await store.load(id: entry.id)) ?? ""
            let custom = await store.isCustom(id: entry.id)
            entry.content = content
            entry.isCustom = custom
            loaded.append(entry)
        }
        entries = loaded
        if selectedID == nil {
            selectedID = entries.first?.id
        }
    }

    /// Saves content for the currently selected entry.
    public func save(content: String) async {
        guard let id = selectedID else { return }
        do {
            try await store.save(id: id, content: content)
            updateEntry(id: id, content: content, isCustom: true)
        } catch {}
    }

    /// Resets the currently selected entry to its bundled default.
    public func reset() async {
        guard let id = selectedID else { return }
        do {
            try await store.reset(id: id)
            let content = (try? await store.load(id: id)) ?? ""
            updateEntry(id: id, content: content, isCustom: false)
        } catch {}
    }

    // MARK: - Private

    private func updateEntry(id: String, content: String, isCustom: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].content = content
        entries[idx].isCustom = isCustom
    }
}
