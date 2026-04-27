import Foundation
import GRDB
import Core
import Storage

/// Smoke-тест GC для classification_log: вставляем старые/новые записи,
/// запускаем GC, проверяем что удалены только старые.
@main
enum RetentionGCSmoke {
    static func main() async throws {
        try await testLogRetentionGC()
        print("✅ RetentionGCSmoke: все проверки пройдены")
    }

    private static func testLogRetentionGC() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention_gc_smoke_\(UUID().uuidString).sqlite")

        // GRDBMetadataStore проводит все миграции и отдаёт pool
        let store = try GRDBMetadataStore(url: dbURL)
        let pool = await store.pool
        let log = ClassificationLog(pool: pool)
        let now = Date()

        // Вставляем «старую» запись (120 дней назад)
        let oldDate = Calendar.current.date(byAdding: .day, value: -120, to: now)!
        let oldEntry = AuditEntry(
            messageIdHash: "hash-old",
            model: "test/model",
            tokensIn: 10, tokensOut: 5, durationMs: 100,
            confidence: 0.9,
            createdAt: oldDate
        )
        try await log.append(oldEntry)

        // Вставляем «новую» запись (10 дней назад)
        let recentDate = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let recentEntry = AuditEntry(
            messageIdHash: "hash-recent",
            model: "test/model",
            tokensIn: 20, tokensOut: 10, durationMs: 200,
            confidence: 0.95,
            createdAt: recentDate
        )
        try await log.append(recentEntry)

        // Проверяем: 2 записи всего
        let beforeGC = try await log.recent(limit: 100)
        precondition(beforeGC.count == 2, "expected 2 entries before GC, got \(beforeGC.count)")

        // GC с retention 90 дней — удалит только старую
        let deleted = try await log.runRetentionGC(olderThanDays: 90, now: now)
        precondition(deleted == 1, "expected 1 deleted, got \(deleted)")

        // Осталась только новая
        let afterGC = try await log.recent(limit: 100)
        precondition(afterGC.count == 1, "expected 1 entry after GC, got \(afterGC.count)")
        precondition(afterGC.first?.messageIdHash == "hash-recent",
                     "surviving entry must be the recent one")

        // GC с retention 5 дней — удалит и новую
        let deleted2 = try await log.runRetentionGC(olderThanDays: 5, now: now)
        precondition(deleted2 == 1, "expected 1 more deleted, got \(deleted2)")

        let finalEntries = try await log.recent(limit: 100)
        precondition(finalEntries.isEmpty, "expected 0 entries after aggressive GC")

        // Cleanup
        try? FileManager.default.removeItem(at: dbURL)
    }
}
