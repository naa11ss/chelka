import Foundation
import SQLite3

/// Постоянное хранилище истории буфера.
///
/// SQLite, а не файл с JSON: запись атомарна, порча при внезапном
/// выключении не теряет всю историю, а выборка не требует держать
/// картинки в памяти. Метаданные и нагрузка шифруются раздельно —
/// список рисуется, не расшифровывая мегабайты картинок.
/// Владелец соединения с базой.
///
/// Отдельный класс, потому что `deinit` актора не имеет права трогать
/// неизолированное состояние: соединение закрывается здесь, когда
/// хранилище освобождается.
private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}

public actor ClipboardStore {

    private let handle: SQLiteHandle
    private var db: OpaquePointer? { handle.pointer }
    private let crypto: ClipboardCrypto
    private let databaseURL: URL

    /// Записи крупнее этого порога не сохраняем: гигабайтная картинка
    /// в буфере не должна раздувать базу и подвешивать интерфейс.
    public static let maxPayloadBytes = 32 * 1024 * 1024

    private static let schemaVersion = 1

    public init(databaseURL: URL, crypto: ClipboardCrypto) throws {
        self.databaseURL = databaseURL
        self.crypto = crypto

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw ChelkaError.storage("не удалось открыть базу по пути \(databaseURL.path)")
        }
        self.handle = SQLiteHandle(pointer: handle)

        try Self.protectOnDisk(databaseURL)
        // Миграция статическая: инициализатор актора не может звать
        // изолированные методы синхронно.
        try Self.migrate(db: handle)
    }

    // MARK: - Схема

    private static func migrate(db: OpaquePointer) throws {
        try execute("PRAGMA journal_mode = WAL;", on: db)
        try execute("PRAGMA synchronous = NORMAL;", on: db)
        try execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """, on: db)
        try execute("""
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL,
                content_key TEXT NOT NULL,
                kind TEXT NOT NULL,
                meta_blob BLOB NOT NULL,
                payload_blob BLOB NOT NULL
            );
            """, on: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC);", on: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_items_content ON items(content_key);", on: db)

        let current = try readSchemaVersion(db: db)
        if current != schemaVersion {
            try execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '\(schemaVersion)');", on: db)
        }
    }

    private static func readSchemaVersion(db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'schema_version';", -1, &statement, nil) == SQLITE_OK else {
            throw ChelkaError.storage("не удалось прочитать версию схемы: \(errorMessage(db))")
        }
        if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            return Int(String(cString: text)) ?? 0
        }
        return 0
    }

    // MARK: - Чтение

    /// Метаданные всех записей. Нагрузка не расшифровывается.
    public func loadItems() throws -> [ClipboardItem] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "SELECT meta_blob FROM items ORDER BY created_at DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ChelkaError.storage("выборка записей не удалась: \(lastErrorMessage)")
        }

        var items: [ClipboardItem] = []
        var damaged = 0

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = blobColumn(statement, index: 0) else { continue }
            do {
                let decrypted = try crypto.open(blob)
                items.append(try JSONDecoder().decode(ClipboardItem.self, from: decrypted))
            } catch {
                // Битая или чужая запись не должна ронять всю историю:
                // например, если ключ в связке пересоздали.
                damaged += 1
            }
        }

        if damaged > 0 {
            Log.clipboard.error("нечитаемых записей: \(damaged) — вероятно, сменился ключ шифрования")
        }
        return items
    }

    /// Нагрузка конкретной записи. Расшифровывается только по требованию.
    public func payload(for id: UUID) throws -> ClipboardPayload? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, "SELECT payload_blob FROM items WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw ChelkaError.storage("выборка нагрузки не удалась: \(lastErrorMessage)")
        }
        bindText(statement, index: 1, value: id.uuidString)

        guard sqlite3_step(statement) == SQLITE_ROW, let blob = blobColumn(statement, index: 0) else {
            return nil
        }
        let decrypted = try crypto.open(blob)
        return try JSONDecoder().decode(ClipboardPayload.self, from: decrypted)
    }

    // MARK: - Запись

    public func save(item: ClipboardItem, payload: ClipboardPayload) throws {
        guard payload.byteSize <= Self.maxPayloadBytes else {
            throw ChelkaError.storage("запись \(payload.byteSize) Б превышает предел \(Self.maxPayloadBytes) Б")
        }

        let metaBlob = try crypto.seal(try JSONEncoder().encode(item))
        let payloadBlob = try crypto.seal(try JSONEncoder().encode(payload))

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = """
            INSERT OR REPLACE INTO items
                (id, created_at, is_pinned, content_key, kind, meta_blob, payload_blob)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ChelkaError.storage("подготовка вставки не удалась: \(lastErrorMessage)")
        }

        bindText(statement, index: 1, value: item.id.uuidString)
        sqlite3_bind_double(statement, 2, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, item.isPinned ? 1 : 0)
        bindText(statement, index: 4, value: item.contentKey)
        bindText(statement, index: 5, value: item.kind.rawValue)
        bindBlob(statement, index: 6, value: metaBlob)
        bindBlob(statement, index: 7, value: payloadBlob)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ChelkaError.storage("вставка не удалась: \(lastErrorMessage)")
        }
    }

    /// Обновляет только метаданные — например, после закрепления или подъёма
    /// записи наверх. Нагрузку не трогаем: она не менялась.
    public func updateMeta(_ item: ClipboardItem) throws {
        let metaBlob = try crypto.seal(try JSONEncoder().encode(item))

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "UPDATE items SET created_at = ?, is_pinned = ?, meta_blob = ? WHERE id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ChelkaError.storage("подготовка обновления не удалась: \(lastErrorMessage)")
        }

        sqlite3_bind_double(statement, 1, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, item.isPinned ? 1 : 0)
        bindBlob(statement, index: 3, value: metaBlob)
        bindText(statement, index: 4, value: item.id.uuidString)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ChelkaError.storage("обновление не удалось: \(lastErrorMessage)")
        }
    }

    public func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }

        try execute("BEGIN;")
        do {
            for id in ids {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }

                guard sqlite3_prepare_v2(db, "DELETE FROM items WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                    throw ChelkaError.storage("подготовка удаления не удалась: \(lastErrorMessage)")
                }
                bindText(statement, index: 1, value: id.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw ChelkaError.storage("удаление не удалось: \(lastErrorMessage)")
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func deleteAll(keepPinned: Bool) throws {
        try execute(keepPinned ? "DELETE FROM items WHERE is_pinned = 0;" : "DELETE FROM items;")
        try execute("VACUUM;")
    }

    /// Сбрасывает журнал WAL в основной файл. Нужно перед выходом
    /// и в проверках, читающих файл базы напрямую.
    public func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Размер базы на диске — для панели настроек.
    public func databaseSize() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return (attributes?[.size] as? Int) ?? 0
    }

    // MARK: - Вспомогательное

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: db)
    }

    private static func execute(_ sql: String, on db: OpaquePointer?) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "неизвестная ошибка"
            sqlite3_free(errorPointer)
            throw ChelkaError.storage("\(message) — SQL: \(sql.prefix(60))")
        }
    }

    private var lastErrorMessage: String { Self.errorMessage(db) }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "нет описания" }
        return String(cString: message)
    }

    /// SQLite должен скопировать переданные байты: Swift-значение живёт
    /// только до конца вызова.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bindBlob(_ statement: OpaquePointer?, index: Int32, value: Data) {
        value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
        }
    }

    private func blobColumn(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    /// База с историей буфера не должна читаться другими пользователями
    /// и уезжать в резервные копии.
    private static func protectOnDisk(_ url: URL) throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
