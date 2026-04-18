import Foundation

/// AI-оценка важности. В MVP всегда `.unknown` — ставится AI-pack'ом позже.
public enum Importance: String, Sendable, Hashable, Codable, CaseIterable {
    case unknown
    case important
    case unimportant
}
