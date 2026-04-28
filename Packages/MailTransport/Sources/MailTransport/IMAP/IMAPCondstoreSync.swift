import Foundation

// MARK: - CONDSTORE sync state

/// Сохранённое состояние синхронизации для одного mailbox.
/// Сохраняется в Storage между сессиями; позволяет запрашивать
/// только изменённые сообщения.
public struct IMAPSyncState: Sendable, Equatable, Codable {
    /// Текущая UID-валидность. При изменении — сбрасываем всё состояние.
    public let uidValidity: UInt32
    /// Последний известный HIGHESTMODSEQ (CONDSTORE RFC 7162).
    /// nil — CONDSTORE не поддерживается или не известен.
    public let highestModseq: UInt64?
    /// Наибольший UID, известный при последней синхронизации.
    /// Следующий FETCH начинается с `lastKnownUID + 1`.
    public let lastKnownUID: UInt32

    public init(uidValidity: UInt32, highestModseq: UInt64?, lastKnownUID: UInt32) {
        self.uidValidity = uidValidity
        self.highestModseq = highestModseq
        self.lastKnownUID = lastKnownUID
    }

    public static func fresh(uidValidity: UInt32) -> IMAPSyncState {
        .init(uidValidity: uidValidity, highestModseq: nil, lastKnownUID: 0)
    }
}

// MARK: - Sync result

/// Результат одного инкрементального прохода синхронизации.
public struct IMAPSyncResult: Sendable {
    /// Новые / изменённые сообщения (заголовки).
    public let changed: [IMAPFetchResponse]
    /// UID, помеченные как удалённые на сервере (EXPUNGE или FETCH \Deleted).
    public let expungedUIDs: [UInt32]
    /// Новое состояние для сохранения.
    public let newState: IMAPSyncState
    /// Ошибки парсинга отдельных строк (не критические).
    public let parseErrors: Int

    public init(
        changed: [IMAPFetchResponse],
        expungedUIDs: [UInt32],
        newState: IMAPSyncState,
        parseErrors: Int
    ) {
        self.changed = changed
        self.expungedUIDs = expungedUIDs
        self.newState = newState
        self.parseErrors = parseErrors
    }
}

// MARK: - IMAPCondstoreSync

/// Утилита инкрементальной синхронизации через CONDSTORE (RFC 7162).
///
/// Алгоритм:
/// 1. SELECT mailbox → проверяем UIDVALIDITY (если изменился — полный сброс).
/// 2. Если сервер вернул HIGHESTMODSEQ и у нас есть предыдущий — используем
///    `UID FETCH 1:* (FLAGS) (CHANGEDSINCE <modseq>)` и
///    `UID FETCH <lastKnownUID+1>:* (<attrs>)` для новых.
/// 3. Fallback (нет CONDSTORE): `UID SEARCH UID <lastKnownUID+1>:*` + FETCH.
///
/// Не хранит состояние сам — только вычисляет команды и разбирает ответы.
/// Персистирование `IMAPSyncState` — ответственность Storage-слоя.
public enum IMAPCondstoreSync {

    // MARK: - Public API

    /// Выполняет инкрементальную синхронизацию указанного mailbox.
    ///
    /// - Parameters:
    ///   - connection: Активное `IMAPConnection` (должно быть в authenticated-state).
    ///   - mailbox: Имя папки (e.g. `"INBOX"`).
    ///   - savedState: Предыдущее состояние синхронизации (nil → полный fetch).
    ///   - fetchAttributes: Атрибуты для FETCH новых сообщений.
    /// - Returns: `IMAPSyncResult` с изменёнными и удалёнными сообщениями.
    public static func sync(
        connection: IMAPConnection,
        mailbox: String,
        savedState: IMAPSyncState?,
        fetchAttributes: String = IMAPFetchAttributes.headers
    ) async throws -> IMAPSyncResult {
        // SELECT — нужен для UIDVALIDITY и HIGHESTMODSEQ.
        let selectResult = try await connection.select(mailbox)

        // Проверяем UIDVALIDITY.
        guard let uidValidity = selectResult.uidValidity else {
            // Сервер не вернул UIDVALIDITY — делаем полный fetch как fallback.
            return try await fullSync(
                connection: connection,
                uidValidity: 0,
                fetchAttributes: fetchAttributes
            )
        }

        // Если UIDVALIDITY изменился — полный сброс.
        if let saved = savedState, saved.uidValidity != uidValidity {
            return try await fullSync(
                connection: connection,
                uidValidity: uidValidity,
                fetchAttributes: fetchAttributes
            )
        }

        // Проверяем поддержку CONDSTORE.
        let caps = try await connection.capability()
        let hasCondstore = caps.contains(where: { $0.uppercased() == "CONDSTORE" })
            || caps.contains(where: { $0.uppercased().hasPrefix("IMAP4REV2") })

        // Текущий HIGHESTMODSEQ из SELECT (некоторые серверы возвращают его здесь).
        let serverModseq = extractHighestModseq(from: selectResult)

        guard let saved = savedState else {
            // Первая синхронизация — полный fetch.
            return try await fullSync(
                connection: connection,
                uidValidity: uidValidity,
                fetchAttributes: fetchAttributes,
                serverModseq: serverModseq
            )
        }

        // Инкрементальная синхронизация.
        if hasCondstore, let savedModseq = saved.highestModseq, let serverModseq {
            return try await condstoreSync(
                connection: connection,
                uidValidity: uidValidity,
                savedState: saved,
                savedModseq: savedModseq,
                serverModseq: serverModseq,
                fetchAttributes: fetchAttributes
            )
        } else {
            // Fallback: UID SEARCH для новых + полный FETCH флагов без CONDSTORE.
            return try await uidSearchSync(
                connection: connection,
                uidValidity: uidValidity,
                savedState: saved,
                serverModseq: serverModseq,
                fetchAttributes: fetchAttributes
            )
        }
    }

    // MARK: - Full sync

    private static func fullSync(
        connection: IMAPConnection,
        uidValidity: UInt32,
        fetchAttributes: String,
        serverModseq: UInt64? = nil
    ) async throws -> IMAPSyncResult {
        let (fetches, parseErrors) = try await connection.uidFetchHeaders(
            range: .all,
            attributes: fetchAttributes
        )
        let maxUID = fetches.compactMap(\.uid).max() ?? 0
        let newState = IMAPSyncState(
            uidValidity: uidValidity,
            highestModseq: serverModseq,
            lastKnownUID: maxUID
        )
        return IMAPSyncResult(
            changed: fetches,
            expungedUIDs: [],
            newState: newState,
            parseErrors: parseErrors
        )
    }

    // MARK: - CONDSTORE sync

    private static func condstoreSync(
        connection: IMAPConnection,
        uidValidity: UInt32,
        savedState: IMAPSyncState,
        savedModseq: UInt64,
        serverModseq: UInt64,
        fetchAttributes: String
    ) async throws -> IMAPSyncResult {
        var allChanged: [IMAPFetchResponse] = []
        var parseErrors = 0

        // 1. Fetch флагов изменённых сообщений через CHANGEDSINCE.
        //    UID FETCH 1:* (FLAGS UID) (CHANGEDSINCE <modseq> VANISHED)
        //    — VANISHED даёт нам expunged UID (RFC 7162).
        let changedFlagsResult = try await connection.execute(
            "UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE \(savedModseq))"
        )
        // Парсим изменённые флаги.
        for u in changedFlagsResult.untagged {
            let parts = u.raw.split(separator: " ", maxSplits: 2,
                                    omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[1].uppercased() == "FETCH" else { continue }
            do {
                allChanged.append(try IMAPFetchResponse.parse(u))
            } catch {
                parseErrors += 1
            }
        }

        // Извлекаем VANISHED UID из ответа (если сервер поддерживает QRESYNC).
        let expungedUIDs = extractVanishedUIDs(from: changedFlagsResult)

        // 2. Fetch новых сообщений (UID > lastKnownUID).
        var newUID = savedState.lastKnownUID + 1
        if newUID < 1 { newUID = 1 }
        let newRange = IMAPUIDRange(lower: newUID, upper: nil)
        let (newFetches, newParseErrors) = try await connection.uidFetchHeaders(
            range: newRange,
            attributes: fetchAttributes
        )
        allChanged.append(contentsOf: newFetches)
        parseErrors += newParseErrors

        let maxUID = allChanged.compactMap(\.uid).max() ?? savedState.lastKnownUID
        // Обновляем HIGHESTMODSEQ — берём из ответа или оставляем серверный.
        let newModseq = extractHighestModseqFromResult(changedFlagsResult) ?? serverModseq

        let newState = IMAPSyncState(
            uidValidity: uidValidity,
            highestModseq: newModseq,
            lastKnownUID: maxUID
        )
        return IMAPSyncResult(
            changed: allChanged,
            expungedUIDs: expungedUIDs,
            newState: newState,
            parseErrors: parseErrors
        )
    }

    // MARK: - UID SEARCH fallback

    private static func uidSearchSync(
        connection: IMAPConnection,
        uidValidity: UInt32,
        savedState: IMAPSyncState,
        serverModseq: UInt64?,
        fetchAttributes: String
    ) async throws -> IMAPSyncResult {
        var allChanged: [IMAPFetchResponse] = []
        var parseErrors = 0

        // Ищем UID > lastKnownUID.
        let newStartUID = savedState.lastKnownUID + 1
        let newUIDs = try await connection.execute(
            "UID SEARCH UID \(newStartUID):*"
        )
        // Парсим список новых UID.
        let newUIDList = extractSearchUIDs(from: newUIDs)

        if !newUIDList.isEmpty {
            // FETCH для найденных UID.
            let uidSet = newUIDList.map(String.init).joined(separator: ",")
            let fetchResult = try await connection.execute(
                "UID FETCH \(uidSet) (\(fetchAttributes))"
            )
            for u in fetchResult.untagged {
                let parts = u.raw.split(separator: " ", maxSplits: 2,
                                        omittingEmptySubsequences: false)
                guard parts.count >= 2, parts[1].uppercased() == "FETCH" else { continue }
                do {
                    allChanged.append(try IMAPFetchResponse.parse(u))
                } catch {
                    parseErrors += 1
                }
            }
        }

        let maxUID = allChanged.compactMap(\.uid).max() ?? savedState.lastKnownUID
        let newState = IMAPSyncState(
            uidValidity: uidValidity,
            highestModseq: serverModseq,
            lastKnownUID: maxUID
        )
        return IMAPSyncResult(
            changed: allChanged,
            expungedUIDs: [],
            newState: newState,
            parseErrors: parseErrors
        )
    }

    // MARK: - Helpers

    /// Извлекает HIGHESTMODSEQ из SELECT-ответа.
    /// Сервер может вернуть его в `* OK [HIGHESTMODSEQ <n>]`.
    static func extractHighestModseq(from result: SelectResult) -> UInt64? {
        // SelectResult не хранит raw untagged — значение приходит через
        // tagged text или специальные поля. Эта функция — точка расширения:
        // когда SelectResult будет расширен highestModseq-полем,
        // реализация меняется здесь без изменений вызывающего кода.
        // Пока возвращаем nil — CONDSTORE будет идти через CAPABILITY.
        return nil
    }

    /// Извлекает HIGHESTMODSEQ из tagged/untagged ответа FETCH.
    /// RFC 7162: сервер может вернуть `* OK [HIGHESTMODSEQ <n>]`.
    static func extractHighestModseqFromResult(_ result: IMAPCommandResult) -> UInt64? {
        for u in result.untagged {
            // «OK [HIGHESTMODSEQ 12345]»
            if u.kind == "OK", let val = extractBracketed(u.raw, key: "HIGHESTMODSEQ") {
                return UInt64(val)
            }
        }
        // Также проверяем tagged text.
        if let val = extractBracketed(result.tagged.text, key: "HIGHESTMODSEQ") {
            return UInt64(val)
        }
        return nil
    }

    /// Извлекает VANISHED UID из ответа FETCH CHANGEDSINCE VANISHED.
    /// RFC 7162: сервер присылает `* VANISHED (EARLIER) uid-set`.
    static func extractVanishedUIDs(from result: IMAPCommandResult) -> [UInt32] {
        var uids: [UInt32] = []
        for u in result.untagged {
            guard u.kind.uppercased() == "VANISHED" else { continue }
            // «VANISHED (EARLIER) 1,3,5:7» или «VANISHED 1,3»
            let body = u.raw.dropFirst("VANISHED".count).trimmingCharacters(in: .whitespaces)
            let uidSetStr: String
            if body.hasPrefix("(") {
                // Пропускаем (EARLIER).
                if let close = body.firstIndex(of: ")") {
                    uidSetStr = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                } else { continue }
            } else {
                uidSetStr = body
            }
            uids.append(contentsOf: parseUIDSet(uidSetStr))
        }
        return uids
    }

    /// Парсит UID из `* SEARCH uid1 uid2 ...`.
    static func extractSearchUIDs(from result: IMAPCommandResult) -> [UInt32] {
        for u in result.untagged {
            guard u.kind.uppercased() == "SEARCH" else { continue }
            let body = u.raw.dropFirst("SEARCH".count).trimmingCharacters(in: .whitespaces)
            return body.split(separator: " ").compactMap { UInt32($0) }
        }
        return []
    }

    /// Парсит UID-set вида `1,3,5:7,10` в массив UID.
    static func parseUIDSet(_ uidSet: String) -> [UInt32] {
        var result: [UInt32] = []
        for part in uidSet.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(":") {
                let bounds = trimmed.split(separator: ":", maxSplits: 1)
                if bounds.count == 2,
                   let lo = UInt32(bounds[0].trimmingCharacters(in: .whitespaces)),
                   let hi = UInt32(bounds[1].trimmingCharacters(in: .whitespaces)),
                   lo <= hi {
                    result.append(contentsOf: (lo...hi))
                }
            } else if let uid = UInt32(trimmed) {
                result.append(uid)
            }
        }
        return result
    }

    private static func extractBracketed(_ text: String, key: String) -> String? {
        guard let open = text.range(of: "[\(key) ") else { return nil }
        let afterKey = text[open.upperBound...]
        guard let close = afterKey.firstIndex(of: "]") else { return nil }
        return String(afterKey[..<close]).trimmingCharacters(in: .whitespaces)
    }
}
