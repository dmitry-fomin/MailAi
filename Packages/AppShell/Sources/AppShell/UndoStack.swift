import Foundation

/// LIFO-стек последних действий пользователя для `⌘Z`. Хранит до `capacity`
/// действий в памяти (не на диске). В v1 — только `.move`, расширяется
/// вариантами в следующих фичах.
public actor UndoStack {
    public enum Action: Sendable, Hashable {
        case move(messageIDs: [String], from: String, to: String)
    }

    public let capacity: Int
    private var items: [Action] = []

    public init(capacity: Int = 20) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    public func push(_ action: Action) {
        items.append(action)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    public func pop() -> Action? {
        items.popLast()
    }

    public func snapshot() -> [Action] { items }

    public func clear() { items.removeAll(keepingCapacity: false) }

    public var count: Int { items.count }
}
