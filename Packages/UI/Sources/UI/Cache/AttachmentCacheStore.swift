// Packages/UI/Sources/UI/Cache/AttachmentCacheStore.swift
import CryptoKit
import Foundation

struct AttachmentMeta: Codable {
    let mimeType: String
    let size: Int
    let messageIDHash: String
}

public actor AttachmentCacheStore {
    private let attachDir: URL

    public init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.attachDir = dir.appendingPathComponent("attachments")
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.attachDir = caches.appendingPathComponent("MailAi/attachments")
        }
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
    }

    public func read(messageID: String, contentID: String) async -> (Data, String)? {
        let binURL = binFileURL(messageID: messageID, contentID: contentID)
        let metaURL = metaFileURL(messageID: messageID, contentID: contentID)
        guard let data = try? Data(contentsOf: binURL),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(AttachmentMeta.self, from: metaData)
        else { return nil }
        // Обновляем дату доступа у ОБОИХ файлов — allFiles() читает дату у .meta
        let now = Date()
        try? (binURL as NSURL).setResourceValue(now, forKey: .contentAccessDateKey)
        try? (metaURL as NSURL).setResourceValue(now, forKey: .contentAccessDateKey)
        return (data, meta.mimeType)
    }

    public func write(messageID: String, contentID: String, data: Data, mimeType: String) async {
        let binURL = binFileURL(messageID: messageID, contentID: contentID)
        let metaURL = metaFileURL(messageID: messageID, contentID: contentID)
        let meta = AttachmentMeta(
            mimeType: mimeType,
            size: data.count,
            messageIDHash: Self.sha256(messageID)
        )
        try? data.write(to: binURL, options: .atomic)
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    public func clearAll() async -> Int {
        let size = totalSizeSync()
        try? FileManager.default.removeItem(at: attachDir)
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        return size
    }

    public func totalSize() async -> Int { totalSizeSync() }

    // MARK: - Internal

    func allFiles() -> [(url: URL, date: Date, messageIDHash: String)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: attachDir,
            includingPropertiesForKeys: [.contentAccessDateKey]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "meta" }
            .compactMap { metaURL in
                guard let metaData = try? Data(contentsOf: metaURL),
                      let meta = try? JSONDecoder().decode(AttachmentMeta.self, from: metaData)
                else { return nil }
                let date = (try? metaURL.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
                return (metaURL, date, meta.messageIDHash)
            }
    }

    func deleteByMessageIDHash(_ messageIDHash: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: attachDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in items {
            guard url.pathExtension == "meta",
                  let metaData = try? Data(contentsOf: url),
                  let meta = try? JSONDecoder().decode(AttachmentMeta.self, from: metaData),
                  meta.messageIDHash == messageIDHash
            else { continue }
            try? FileManager.default.removeItem(at: url)
            let binURL = url.deletingPathExtension().appendingPathExtension("bin")
            try? FileManager.default.removeItem(at: binURL)
        }
    }

    public static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func binFileURL(messageID: String, contentID: String) -> URL {
        let hash = Self.sha256(messageID + contentID)
        return attachDir.appendingPathComponent("\(hash).bin")
    }

    private func metaFileURL(messageID: String, contentID: String) -> URL {
        let hash = Self.sha256(messageID + contentID)
        return attachDir.appendingPathComponent("\(hash).meta")
    }

    private func totalSizeSync() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: attachDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
