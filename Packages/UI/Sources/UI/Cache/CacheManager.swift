// Packages/UI/Sources/UI/Cache/CacheManager.swift
import Foundation

public actor CacheManager {
    private let bodyCache: MessageBodyCache
    private let attachmentCache: AttachmentCacheStore
    private var limitBytes: Int

    public static let defaultLimitBytes = 500 * 1024 * 1024  // 500 МБ
    public static let shared = CacheManager(
        bodyCache: MessageBodyCache(),
        attachmentCache: AttachmentCacheStore()
    )

    public init(
        bodyCache: MessageBodyCache,
        attachmentCache: AttachmentCacheStore,
        limitBytes: Int? = nil
    ) {
        self.bodyCache = bodyCache
        self.attachmentCache = attachmentCache
        self.limitBytes = limitBytes ?? UserDefaults.standard.integer(forKey: "cacheLimitBytes")
            .nonZero ?? CacheManager.defaultLimitBytes
    }

    // MARK: - Public API

    public func readBody(messageID: String) async -> String? {
        await bodyCache.read(messageID: messageID)
    }

    public func writeBody(messageID: String, processedHTML: String) async {
        await bodyCache.write(messageID: messageID, processedHTML: processedHTML)
        await evictIfNeeded()
    }

    public func invalidateBody(messageID: String) async {
        await bodyCache.invalidate(messageID: messageID)
    }

    public func readAttachment(messageID: String, contentID: String) async -> (Data, String)? {
        await attachmentCache.read(messageID: messageID, contentID: contentID)
    }

    public func writeAttachment(messageID: String, contentID: String, data: Data, mimeType: String) async {
        await attachmentCache.write(messageID: messageID, contentID: contentID, data: data, mimeType: mimeType)
        await evictIfNeeded()
    }

    public func totalSize() async -> Int {
        await bodyCache.totalSize() + attachmentCache.totalSize()
    }

    public func clearAll() async {
        _ = await bodyCache.clearAll()
        _ = await attachmentCache.clearAll()
    }

    public func setLimit(bytes: Int) {
        limitBytes = bytes
        UserDefaults.standard.set(bytes, forKey: "cacheLimitBytes")
    }

    public var formattedSize: String {
        get async {
            let bytes = await totalSize()
            let mb = Double(bytes) / 1_048_576
            let limit = Double(limitBytes) / 1_048_576
            return String(format: "%.0f МБ из %.0f МБ", mb, limit)
        }
    }

    // MARK: - LRU eviction

    public func evictIfNeeded() async {
        let total = await totalSize()
        guard total > limitBytes else { return }

        let bodyFiles = await bodyCache.allFiles()
        let sorted = bodyFiles.sorted { $0.date < $1.date }

        var current = total
        for entry in sorted {
            guard current > limitBytes else { break }
            let bodySize = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let attachSize = await attachmentCache.sizeForMessageIDHash(entry.messageIDHash)
            try? FileManager.default.removeItem(at: entry.url)
            await attachmentCache.deleteByMessageIDHash(entry.messageIDHash)
            current -= bodySize + attachSize
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Settings ViewModel

@MainActor
public final class CacheSettingsViewModel: ObservableObject {
    @Published public var formattedSize: String = "—"
    @Published public var limitMB: Int

    private let manager: CacheManager

    public init(manager: CacheManager = .shared) {
        self.manager = manager
        self.limitMB = (UserDefaults.standard.integer(forKey: "cacheLimitBytes").nonZero
            ?? CacheManager.defaultLimitBytes) / (1024 * 1024)
    }

    public func refresh() async {
        formattedSize = await manager.formattedSize
    }

    public func clearCache() async {
        await manager.clearAll()
        await refresh()
    }

    public func updateLimit() {
        let bytes = limitMB * 1024 * 1024
        Task { await manager.setLimit(bytes: bytes) }
    }
}
