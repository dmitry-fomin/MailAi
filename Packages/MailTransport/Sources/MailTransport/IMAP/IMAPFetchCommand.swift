import Foundation
import Core

/// Диапазон UID для FETCH. `1:*` — вся папка, `100:200` — ограниченный срез.
/// UID (а не sequence numbers) стабильны относительно expunge — используем их
/// как источник истины для upsert в `MetadataStore`.
public struct IMAPUIDRange: Sendable, Equatable {
    public let lower: UInt32
    public let upper: UInt32?  // nil == '*'

    public init(lower: UInt32, upper: UInt32?) {
        self.lower = lower
        self.upper = upper
    }

    public static let all: IMAPUIDRange = .init(lower: 1, upper: nil)

    public static func range(_ range: ClosedRange<UInt32>) -> IMAPUIDRange {
        .init(lower: range.lowerBound, upper: range.upperBound)
    }

    public var command: String {
        let upperStr = upper.map(String.init) ?? "*"
        return "\(lower):\(upperStr)"
    }
}

/// Набор атрибутов, которые B6 запрашивает одной FETCH-командой. Порядок
/// сохраняем, чтобы соответствовать логам реальных серверов — это упрощает
/// сверку при диагностике.
public enum IMAPFetchAttributes {
    public static let headers = "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE"

    public static func uidFetchCommand(range: IMAPUIDRange, attributes: String = headers) -> String {
        "UID FETCH \(range.command) (\(attributes))"
    }
}
