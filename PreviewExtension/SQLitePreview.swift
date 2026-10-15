import QuickPeekFormats
import SwiftUI

/// A SQLite database: its tables and views on the left, the first rows of the selected one on the right.
struct SQLitePreview: View {
    static let extensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "sqlitedb"]

    let fileName: String
    let fileSize: Int64
    let database: SQLiteDatabase
    @State private var selection: String?
    @State private var rows: [Row] = []
    @State private var problem: String?

    static let rowLimit = 200

    struct Row: Identifiable {
        let id: Int
        let values: [SQLiteDatabase.Value]
    }

    private var summary: String {
        let tables = database.tables.filter { $0.kind == .table }.count
        let views = database.tables.count - tables
        var parts = ["SQLite", tables == 1 ? "1 table" : "\(tables.formatted()) tables"]
        if views > 0 { parts.append(views == 1 ? "1 view" : "\(views.formatted()) views") }
        parts.append(Format.bytes(fileSize))
        return parts.joined(separator: " · ")
    }

    private var selected: SQLiteDatabase.Table? {
        database.tables.first { $0.name == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewHeader(symbol: "cylinder.split.1x2", title: fileName, subtitle: summary)
            if database.tables.isEmpty {
                ContentUnavailableView("No Tables", systemImage: "tablecells")
            } else {
                HSplitView {
                    tableList.frame(minWidth: 150, idealWidth: 200, maxWidth: 240)
                    rowsPane.frame(minWidth: 320, maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            // Start with the biggest table: usually the one the database is about.
            selection = database.tables.max { ($0.rowCount ?? -1) < ($1.rowCount ?? -1) }?.name
        }
        .onChange(of: selection, initial: false) { load() }
    }

    private var tableList: some View {
        List(database.tables, selection: $selection) { table in
            Label {
                HStack {
                    Text(table.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let count = table.rowCount {
                        Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: table.kind == .view ? "eye" : "tablecells")
            }
            .tag(table.name)
        }
    }

    @ViewBuilder private var rowsPane: some View {
        if let problem {
            ContentUnavailableView("Cannot Read Rows", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if let table = selected {
            VStack(alignment: .leading, spacing: 0) {
                Text(caption(table))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                rowsTable(table).id(table.name)
            }
        }
    }

    /// Row count and the columns with their declared types, like a short schema.
    private func caption(_ table: SQLiteDatabase.Table) -> String {
        var parts: [String] = []
        if let count = table.rowCount {
            parts.append(count == 1 ? "1 row" : "\(count.formatted()) rows")
            if count > Self.rowLimit { parts.append("first \(Self.rowLimit) shown") }
        } else if rows.count == Self.rowLimit {
            parts.append("first \(Self.rowLimit) rows shown")
        }
        let columns = table.columns.map { column in
            [column.name, column.type, column.isPrimaryKey ? "PK" : ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return (parts + [columns.joined(separator: ", ")]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func rowsTable(_ table: SQLiteDatabase.Table) -> some View {
        let width = max(table.columns.count, rows.first?.values.count ?? 0)
        let names = (0..<width).map { $0 < table.columns.count ? table.columns[$0].name : "column \($0 + 1)" }
        return Table(of: Row.self) {
            TableColumnForEach(names.indices, id: \.self) { index in
                TableColumn(names[index]) { row in
                    cell(index < row.values.count ? row.values[index] : .null)
                }
                .width(min: 50, ideal: 110)
            }
        } rows: {
            ForEach(rows) { TableRow($0) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder private func cell(_ value: SQLiteDatabase.Value) -> some View {
        switch value {
        case .null: Text("NULL").italic().foregroundStyle(.tertiary)
        case .integer(let number): Text(String(number)).monospacedDigit()
        case .real(let number): Text(String(number)).monospacedDigit()
        case .text(let text): Text(text).lineLimit(1).help(text.count > 40 ? text : "")
        case .blob(let size): Text("BLOB · \(Format.bytes(Int64(size)))").foregroundStyle(.secondary)
        }
    }

    private func load() {
        guard let selection else { return }
        do {
            rows = try database.rows(of: selection, limit: Self.rowLimit).enumerated().map { Row(id: $0.offset, values: $0.element) }
            problem = nil
        } catch SQLiteError.unreadable(let message) {
            rows = []
            problem = message
        } catch {
            rows = []
            problem = error.localizedDescription
        }
    }
}
