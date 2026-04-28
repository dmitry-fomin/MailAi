import CryptoKit
import Foundation

public actor MessageBodyCache {
    private let bodiesDir: URL

    public init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.bodiesDir = dir.appendingPathComponent("bodies")
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.bodiesDir = caches.appendingPathComponent("MailAi/bodies")
        }
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
    }

    public func read(messageID: String) async -> String? {
        let url = fileURL(for: messageID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? (url as NSURL).setResourceValue(Date(), forKey: .contentAccessDateKey)
        return String(data: data, encoding: .utf8)
    }

    public func write(messageID: String, processedHTML: String) async {
        let url = fileURL(for: messageID)
        try? processedHTML.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    public func invalidate(messageID: String) async {
        try? FileManager.default.removeItem(at: fileURL(for: messageID))
    }

    public func clearAll() async -> Int {
        let size = totalSizeSync()
        try? FileManager.default.removeItem(at: bodiesDir)
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
        return size
    }

    public func totalSize() async -> Int { totalSizeSync() }

    func fileURL(for messageID: String) -> URL {
        let hash = SHA256.hash(data: Data(messageID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return bodiesDir.appendingPathComponent("\(hash).html")
    }

    func allFiles() -> [(url: URL, date: Date, messageIDHash: String)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: bodiesDir, includingPropertiesForKeys: [.contentAccessDateKey]
        ) else { return [] }
        return items.compactMap { url in
            guard url.pathExtension == "html" else { return nil }
            let hash = url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? Date.distantPast
            return (url, date, hash)
        }
    }

    private func totalSizeSync() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: bodiesDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
