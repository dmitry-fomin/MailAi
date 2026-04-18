import Foundation
import Core

public enum SidebarSectionKind: String, Sendable, Hashable, Codable {
    case favorites
    case smartBoxes
    case onMyMac
    case account
}

public struct SidebarItem: Sendable, Hashable, Identifiable {
    public struct ID: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }

    public enum Kind: Sendable, Hashable {
        case favoriteFlagged
        case favoriteDrafts
        case smartImportant
        case smartUnimportant
        case smartUnread
        case localFolder(name: String)
        case mailbox(Mailbox.ID, role: Mailbox.Role)
    }

    public let id: ID
    public let title: String
    public let systemImage: String
    public let unreadCount: Int
    public let kind: Kind

    public init(id: ID, title: String, systemImage: String, unreadCount: Int, kind: Kind) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.unreadCount = unreadCount
        self.kind = kind
    }
}

public struct SidebarSection: Sendable, Hashable, Identifiable {
    public let id: SidebarSectionKind
    public let title: String
    public let items: [SidebarItem]

    public init(id: SidebarSectionKind, title: String, items: [SidebarItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public enum SidebarIcon {
    public static func name(for role: Mailbox.Role) -> String {
        switch role {
        case .inbox:   return "tray.and.arrow.down"
        case .sent:    return "paperplane"
        case .drafts:  return "square.and.pencil"
        case .archive: return "archivebox"
        case .trash:   return "trash"
        case .spam:    return "exclamationmark.octagon"
        case .flagged: return "flag"
        case .custom:  return "folder"
        }
    }
}
