import Foundation
import SQLite3

/// SQL arguments and result values: SQLite's five storage classes.
enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func int(_ value: Int) -> SQLValue { .integer(Int64(value)) }
    static func text(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func int(_ value: Int?) -> SQLValue { value.map(SQLValue.int) ?? .null }
    static func uuid(_ value: UUID?) -> SQLValue { .text(value?.uuidString) }
    static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSince1970) }
    static func blob(_ value: Data?) -> SQLValue { value.map(SQLValue.blob) ?? .null }
    /// Unix milliseconds, stored as REAL seconds like every date column; whole milliseconds survive the round trip exactly.
    static func milliseconds(_ value: Int64) -> SQLValue { .real(Double(value) / 1000) }

    var int: Int? { if case .integer(let v) = self { Int(v) } else { nil } }
    var string: String? { if case .text(let v) = self { v } else { nil } }
    var data: Data? { if case .blob(let v) = self { v } else { nil } }
    var uuid: UUID? { string.flatMap(UUID.init(uuidString:)) }
    var date: Date? { if case .real(let v) = self { Date(timeIntervalSince1970: v) } else { nil } }
    /// A date column as whole Unix milliseconds (rounded: rows written before sync may hold finer values). Nil for a value that does
    /// not fit in Int64, so a corrupt row can never crash a read.
    var milliseconds: Int64? {
        switch self {
        case .real(let v):
            return Int64(exactly: (v * 1000).rounded())
        case .integer(let v):
            let (ms, overflow) = v.multipliedReportingOverflow(by: 1000)
            return overflow ? nil : ms
        default:
            return nil
        }
    }
}

/// One result row, indexed by column name; a missing column reads as `.null`.
struct SQLRow {
    fileprivate var values: [String: SQLValue]
    subscript(_ column: String) -> SQLValue { values[column] ?? .null }
}

/// A thin wrapper around the system SQLite. Not Sendable: owned and used serially by a single actor (BookStore).
/// Values are always bound as parameters, never spliced into SQL; text and blobs are bound with SQLITE_TRANSIENT so SQLite
/// copies them immediately (SQL splicing and dangling pointers passed to `sqlite3_bind_text` are classic ways to get this wrong).
final class SQLiteConnection {
    private let handle: OpaquePointer

    init(path: String) throws(StoreError) {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2"
            sqlite3_close_v2(handle)
            throw StoreError.sqlite(code: code, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Rows changed by the most recent statement.
    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs a statement that returns no rows. Without arguments it may be several statements separated by semicolons (e.g. a migration).
    func execute(_ sql: String, _ arguments: [SQLValue] = []) throws(StoreError) {
        if arguments.isEmpty {
            // sqlite3_exec binds nothing: a stray placeholder would silently run as NULL
            assert(!sql.contains("?"), "SQL with placeholders needs arguments: \(sql)")
            var message: UnsafeMutablePointer<CChar>?
            let code = sqlite3_exec(handle, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            guard code == SQLITE_OK else { throw failure(code, message.map { String(cString: $0) }) }
        } else {
            _ = try query(sql, arguments)
        }
    }

    /// Runs one statement and returns all result rows.
    func query(_ sql: String, _ arguments: [SQLValue] = []) throws(StoreError) -> [SQLRow] {
        var statement: OpaquePointer?
        var code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        precondition(Int(sqlite3_bind_parameter_count(statement)) == arguments.count, "Argument count does not match the SQL: \(sql)")
        for (offset, value) in arguments.enumerated() {
            code = bind(value, at: Int32(offset + 1), in: statement)
            guard code == SQLITE_OK else { throw failure(code) }
        }
        var rows: [SQLRow] = []
        while true {
            code = sqlite3_step(statement)
            guard code == SQLITE_ROW else { break }
            var values: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                values[String(cString: sqlite3_column_name(statement, column))] = value(at: column, in: statement)
            }
            rows.append(SQLRow(values: values))
        }
        guard code == SQLITE_DONE else { throw failure(code) }
        return rows
    }

    /// Runs `body` in a transaction; rolls everything back if `body` throws or the commit fails.
    func transaction<T>(_ body: () throws(StoreError) -> T) throws(StoreError) -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ value: SQLValue, at index: Int32, in statement: OpaquePointer) -> Int32 {
        // SQLITE_TRANSIENT: SQLite copies the data while binding, so Swift's temporary buffer may go away afterwards
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .null: return sqlite3_bind_null(statement, index)
        case .integer(let v): return sqlite3_bind_int64(statement, index, v)
        case .real(let v): return sqlite3_bind_double(statement, index, v)
        case .text(let v): return sqlite3_bind_text(statement, index, v, -1, transient)
        case .blob(let v):
            // Empty Data has a nil baseAddress, which sqlite3_bind_blob stores as NULL; an empty blob needs zeroblob
            if v.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
            return v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        }
    }

    private func value(at column: Int32, in statement: OpaquePointer) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func failure(_ code: Int32, _ message: String? = nil) -> StoreError {
        // The low 8 bits of an extended result code are the primary code; the Unix VFS reports a full disk as SQLITE_FULL
        if code & 0xFF == SQLITE_FULL { return .diskFull }
        return .sqlite(code: code, message: message ?? String(cString: sqlite3_errmsg(handle)))
    }
}
