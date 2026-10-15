import Foundation
import SQLite3

public enum SQLiteError: Error, Equatable {
    case notDatabase
    case unreadable(String)
}

/// A SQLite database opened for previewing with the system libsqlite3, read-only. Tables and views
/// are listed with their columns and row counts; rows are read a page at a time on request.
/// Every statement runs under a time limit, so a huge table or a slow view cannot hang a preview.
public final class SQLiteDatabase {
    public struct Column: Sendable, Equatable {
        public var name: String
        /// Declared type as written in the schema; often empty.
        public var type: String
        public var isPrimaryKey: Bool
    }

    public struct Table: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable { case table, view }
        public var name: String
        public var kind: Kind
        public var columns: [Column]
        /// `nil` for views, and for tables that could not be counted in time.
        public var rowCount: Int?
        public var id: String { name }
    }

    public enum Value: Sendable, Equatable {
        case null
        case integer(Int64)
        case real(Double)
        /// Long text is cut to its beginning.
        case text(String)
        /// Blob contents are not shown, only their size.
        case blob(Int)
    }

    public private(set) var tables: [Table] = []
    private let db: OpaquePointer
    private let deadline = Deadline()

    public init(url: URL, countingTime: TimeInterval = 1) throws {
        let file = try FileHandle(forReadingFrom: url)
        let header = try file.read(upToCount: 16) ?? Data()
        try? file.close()
        guard header == Data("SQLite format 3\0".utf8) else { throw SQLiteError.notDatabase }

        // A plain read-only open sees the newest data, including what still sits in a -wal file.
        // It fails where the sandbox forbids the -shm file next to a WAL database; immutable mode
        // then reads the main file alone, without locks or side files.
        guard let db = Self.open(url, immutable: false) ?? Self.open(url, immutable: true) else {
            throw SQLiteError.unreadable("The database could not be opened.")
        }
        self.db = db
        sqlite3_progress_handler(db, 1000, { context in
            Unmanaged<Deadline>.fromOpaque(context!).takeUnretainedValue().hasPassed ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())

        let schema = try query("SELECT type, name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name COLLATE NOCASE")
        let countUntil = Date().addingTimeInterval(countingTime)
        for row in schema {
            guard case .text(let type) = row[0], case .text(let name) = row[1] else { continue }
            let kind: Table.Kind = type == "view" ? .view : .table
            // Virtual tables whose module macOS lacks (an app's own FTS tokenizer) cannot be read.
            let columns = (try? query("PRAGMA table_info(\(Self.quote(name)))"))?.map { info in
                Column(name: info[1].string, type: info[2].string, isPrimaryKey: info[5] != .integer(0))
            } ?? []
            var count: Int?
            if kind == .table, Date() < countUntil,
               case .integer(let rows)? = (try? query("SELECT count(*) FROM \(Self.quote(name))", until: countUntil))?.first?.first {
                count = Int(rows)
            }
            tables.append(Table(name: name, kind: kind, columns: columns, rowCount: count))
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    /// The first rows of a table or view, in storage order.
    public func rows(of table: String, limit: Int = 200, timeLimit: TimeInterval = 2) throws -> [[Value]] {
        try query("SELECT * FROM \(Self.quote(table)) LIMIT \(limit)", until: Date().addingTimeInterval(timeLimit))
    }

    private func query(_ sql: String, until: Date = .distantFuture) throws -> [[Value]] {
        deadline.time = until
        defer { deadline.time = .distantFuture }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[Value]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { Self.value(statement, $0) })
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError.unreadable(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func value(_ statement: OpaquePointer, _ column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(statement, column)))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let bytes = sqlite3_column_text(statement, column) else { return .text("") }
            let text = String(decoding: UnsafeBufferPointer(start: bytes, count: min(count, 1024)), as: UTF8.self)
            return .text(count > 1024 ? text + "…" : text)
        default: return .null
        }
    }

    private static func open(_ url: URL, immutable: Bool) -> OpaquePointer? {
        var db: OpaquePointer?
        let uri = url.absoluteString + (immutable ? "?immutable=1" : "?mode=ro")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db,
              // Opening is lazy; reading the schema is what touches the file and its WAL.
              sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        return db
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private final class Deadline {
        var time = Date.distantFuture
        var hasPassed: Bool { Date() > time }
    }
}

private extension SQLiteDatabase.Value {
    var string: String {
        if case .text(let text) = self { return text }
        return ""
    }
}
