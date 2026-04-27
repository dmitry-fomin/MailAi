import Foundation
import GRDB
import Core

/// CRUD-репозиторий для подписей пользователя.
///
/// Actor для изоляции состояния; все методы — async throws, конкурентность
/// строго через structured concurrency.
public actor SignaturesRepository {

    // MARK: - Properties

    public nonisolated let pool: DatabasePool

    // MARK: - Init

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Read

    /// Возвращает все подписи, отсортированные по имени.
    public func all() async throws -> [Signature] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM signature ORDER BY name ASC")
                .compactMap(Self.decode)
        }
    }

    // MARK: - Write

    /// Вставляет или обновляет подпись (upsert по id).
    public func upsert(_ sig: Signature) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO signature (id, name, body, is_default)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    body = excluded.body,
                    is_default = excluded.is_default
                """,
                arguments: [
                    sig.id.rawValue,
                    sig.name,
                    sig.body,
                    sig.isDefault ? 1 : 0
                ]
            )
        }
    }

    /// Удаляет подпись по идентификатору.
    public func delete(id: Signature.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM signature WHERE id = ?",
                           arguments: [id.rawValue])
        }
    }

    /// Делает подпись с данным `id` дефолтной, снимая флаг со всех остальных.
    /// Операция атомарна (единственная транзакция).
    public func setDefault(id: Signature.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE signature SET is_default = 0")
            try db.execute(sql: "UPDATE signature SET is_default = 1 WHERE id = ?",
                           arguments: [id.rawValue])
        }
    }

    // MARK: - Decode

    private static func decode(_ row: Row) -> Signature? {
        guard
            let rawID = row["id"] as? String,
            let name = row["name"] as? String,
            let body = row["body"] as? String
        else { return nil }

        // SQLite INTEGER возвращается через GRDB как Int64; приводим явно.
        let isDefaultInt: Int64 = (row["is_default"] as? Int64) ?? 0

        return Signature(
            id: Signature.ID(rawID),
            name: name,
            body: body,
            isDefault: isDefaultInt != 0
        )
    }
}
