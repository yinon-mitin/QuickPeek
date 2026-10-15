import Foundation
import SQLite3
import Testing
@testable import QuickPeekFormats

@Suite("SQLiteDatabase")
struct SQLiteDatabaseTests {
    /// Creates a database in the temporary directory; `keepOpen` returns the writer still connected.
    private func makeDatabase(_ sql: String, name: String = "test.sqlite", keepOpen: Bool = false) throws -> (url: URL, writer: OpaquePointer?) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SQLite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        if keepOpen { return (url, db) }
        sqlite3_close(db)
        return (url, nil)
    }

    @Test("Tables and views with columns, primary keys and row counts")
    func schema() throws {
        let (url, _) = try makeDatabase(#"""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, photo BLOB, score REAL);
            CREATE TABLE "odd ""name""" (x);
            CREATE INDEX people_name ON people(name);
            CREATE VIEW adults AS SELECT name FROM people WHERE score > 1;
            INSERT INTO people (name, photo, score) VALUES ('Ada', x'00010203', 2.5), ('Linus', NULL, 0.5), ('Grace', NULL, NULL);
            """#, name: "with space.db")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let db = try SQLiteDatabase(url: url)
        #expect(db.tables.map(\.name) == ["adults", "odd \"name\"", "people"])
        let people = try #require(db.tables.last)
        #expect(people.kind == .table)
        #expect(people.rowCount == 3)
        #expect(people.columns.map(\.name) == ["id", "name", "photo", "score"])
        #expect(people.columns.map(\.type) == ["INTEGER", "TEXT", "BLOB", "REAL"])
        #expect(people.columns.map(\.isPrimaryKey) == [true, false, false, false])
        #expect(db.tables[0].kind == .view && db.tables[0].rowCount == nil)
        #expect(db.tables[1].rowCount == 0)

        let rows = try db.rows(of: "people")
        #expect(rows[0] == [.integer(1), .text("Ada"), .blob(4), .real(2.5)])
        #expect(rows[2] == [.integer(3), .text("Grace"), .null, .null])
        #expect(try db.rows(of: "adults") == [[.text("Ada")]])
        #expect(try db.rows(of: "people", limit: 1).count == 1)
    }

    @Test("Rows still in the write-ahead log are seen")
    func wal() throws {
        let (url, writer) = try makeDatabase(#"""
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE t (v);
            INSERT INTO t VALUES (1), (2);
            """#, keepOpen: true)
        defer {
            sqlite3_close(writer)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let db = try SQLiteDatabase(url: url)
        #expect(db.tables.first?.rowCount == 2)
    }

    @Test("Long text is cut; a file that is not SQLite is refused")
    func limits() throws {
        let (url, _) = try makeDatabase("CREATE TABLE t (v); INSERT INTO t VALUES (printf('%.*c', 5000, 'a'));")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard case .text(let text) = try SQLiteDatabase(url: url).rows(of: "t")[0][0] else {
            Issue.record("expected text")
            return
        }
        #expect(text.count == 1025 && text.hasSuffix("…"))

        let notDatabase = url.deletingLastPathComponent().appendingPathComponent("Thumbs.db")
        try Data("not a database at all".utf8).write(to: notDatabase)
        #expect(throws: SQLiteError.notDatabase) { try SQLiteDatabase(url: notDatabase) }
    }

    @Test("Identifiers are quoted, so names cannot break out of a statement")
    func quoting() {
        #expect(SQLiteDatabase.quote("a\"; DROP TABLE t; --") == "\"a\"\"; DROP TABLE t; --\"")
    }
}
