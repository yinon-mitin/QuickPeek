import Testing
@testable import QuickPeekCore

@Suite("CSVParser")
struct CSVParserTests {
    @Test("Plain rows")
    func plain() {
        #expect(CSVParser.parse("a,b,c\n1,2,3\n", delimiter: ",") == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test("Quoted fields keep delimiters, escaped quotes and newlines")
    func quoted() {
        let text = "name,note\n\"Doe, John\",\"said \"\"hi\"\"\"\nx,\"two\nlines\"\n"
        #expect(CSVParser.parse(text, delimiter: ",") == [
            ["name", "note"],
            ["Doe, John", "said \"hi\""],
            ["x", "two\nlines"],
        ])
    }

    @Test("CRLF line endings and a missing final newline")
    func crlf() {
        #expect(CSVParser.parse("a,b\r\n1,2", delimiter: ",") == [["a", "b"], ["1", "2"]])
    }

    @Test("Empty fields are preserved")
    func emptyFields() {
        #expect(CSVParser.parse("a,,c\n,,\n", delimiter: ",") == [["a", "", "c"], ["", "", ""]])
    }

    @Test("Row limit stops parsing early")
    func rowLimit() {
        let text = (1...100).map { "\($0),x" }.joined(separator: "\n")
        let rows = CSVParser.parse(text, delimiter: ",", maxRows: 10)
        #expect(rows.count == 10)
        #expect(rows.last == ["10", "x"])
    }

    @Test("Delimiter sniffing", arguments: [
        ("a;b;c\n1;2;3\n", Character(";")),
        ("a\tb\n1\t2\n", "\t"),
        ("a,b\n1,2\n", ","),
        ("a|b|c\n1|2|3\n", "|"),
        ("\"x;y\",b\n1,2\n", ","),
    ])
    func sniff(text: String, expected: Character) {
        #expect(CSVParser.sniffDelimiter(text) == expected)
    }
}
