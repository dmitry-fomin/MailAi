import Foundation
import GRDB
import Core

/// CRUD-репозиторий для подписей пользователя.
///
/// Actor для изоляции состояния; все методы — async throws, конкурентность
/// строго через structured concurrency.
///
/// MailAi-8uz8: подписи могут быть привязаны к аккаунту (`accountID`).
/// При запросе подписей для аккаунта возвращаются:
/// 1. Подписи, привязанные к этому аккаунту.
/// 2. Глобальные подписи (accountID == nil).
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

    /// Возвращает подписи для конкретного аккаунта:
    /// привязанные к нему + глобальные (accountID IS NULL).
    ///
    /// - Parameter accountID: Идентификатор аккаунта.
    public func signatures(for accountID: Account.ID) async throws -> [Signature] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM signature
                    WHERE account_id = ? OR account_id IS NULL
                    ORDER BY
                        CASE WHEN account_id = ? THEN 0 ELSE 1 END,
                        name ASC
                    """,
                arguments: [accountID.rawValue, accountID.rawValue]
            ).compactMap(Self.decode)
        }
    }

    /// Возвращает подпись по умолчанию для аккаунта.
    ///
    /// Приоритет: сначала ищем подпись, привязанную к аккаунту и помеченную
    /// как default. Если не нашли — берём глобальную default. Если и её нет —
    /// возвращаем nil.
    public func defaultSignature(for accountID: Account.ID) async throws -> Signature? {
        try await pool.read { db in
            // Сначала ищем per-account default
            let accountDefault = try Row.fetchOne(
                db,
                sql: "SELECT * FROM signature WHERE account_id = ? AND is_default = 1 LIMIT 1",
                arguments: [accountID.rawValue]
            ).flatMap(Self.decode)

            if let sig = accountDefault { return sig }

            // Затем глобальный default
            return try Row.fetchOne(
                db,
                sql: "SELECT * FROM signature WHERE account_id IS NULL AND is_default = 1 LIMIT 1"
            ).flatMap(Self.decode)
        }
    }

    // MARK: - Write

    /// Вставляет или обновляет подпись (upsert по id).
    public func upsert(_ sig: Signature) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO signature (id, name, body, is_default, account_id)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    body = excluded.body,
                    is_default = excluded.is_default,
                    account_id = excluded.account_id
                """,
                arguments: StatementArguments([
                    sig.id.rawValue,
                    sig.name,
                    sig.body,
                    sig.isDefault ? 1 : 0,
                    sig.accountID?.rawValue as (any DatabaseValueConvertible)?
                ])
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

    /// Делает подпись с данным `id` дефолтной в рамках её аккаунта (или глобально).
    /// Операция атомарна (единственная транзакция).
    ///
    /// - Note: Снимаем флаг `is_default` только у подписей того же `account_id`
    ///   (или у глобальных, если данная подпись глобальная).
    public func setDefault(id: Signature.ID) async throws {
        try await pool.write { db in
            // Получаем account_id нужной подписи
            guard let row = try Row.fetchOne(db,
                sql: "SELECT account_id FROM signature WHERE id = ?",
                arguments: [id.rawValue]) else { return }

            let accountIDValue: String? = row["account_id"]

            // Снимаем флаг у подписей того же scope
            if let aid = accountIDValue {
                try db.execute(sql: "UPDATE signature SET is_default = 0 WHERE account_id = ?",
                               arguments: [aid])
            } else {
                try db.execute(sql: "UPDATE signature SET is_default = 0 WHERE account_id IS NULL")
            }

            // Устанавливаем флаг для нужной подписи
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
        let accountIDRaw: String? = row["account_id"] as? String

        return Signature(
            id: Signature.ID(rawID),
            name: name,
            body: body,
            isDefault: isDefaultInt != 0,
            accountID: accountIDRaw.map { Account.ID($0) }
        )
    }
}
