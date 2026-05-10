import Foundation
import GRDB

/// GC метаданных с тредовой связностью. Удаляет сообщения старше `retentionMonths`
/// месяцев, **кроме** тех, что входят в треды со свежими сообщениями.
///
/// Инвариант: если у треда есть хоть одно сообщение в окне retention, все его
/// сообщения (даже годовалые) сохраняются.
public actor RetentionGC {
    public let pool: DatabasePool
    public let retentionMonths: Int

    public init(pool: DatabasePool, retentionMonths: Int = 6) {
        self.pool = pool
        self.retentionMonths = retentionMonths
    }

    public func run(now: Date = Date()) async throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .month, value: -retentionMonths, to: now) ?? now
        let deleted = try await pool.write { db -> Int in
            try db.execute(sql: """
                DELETE FROM message
                WHERE date < ?
                  AND (thread_id IS NULL
                       OR thread_id NOT IN (
                           SELECT DISTINCT thread_id FROM message
                           WHERE date >= ? AND thread_id IS NOT NULL
                       ))
                """,
                arguments: [cutoff, cutoff]
            )
            // db.changesCount возвращает число строк затронутых последним DML —
            // дешевле двух SELECT COUNT(*).
            return db.changesCount
        }
        return deleted
    }
}
