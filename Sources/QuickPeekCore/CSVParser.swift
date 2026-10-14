/// RFC 4180 style parser for delimited text (CSV, TSV, semicolon-separated exports).
public enum CSVParser {
    public static func parse(_ text: String, delimiter: Character, maxRows: Int = .max) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character.isNewline {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                if rows.count >= maxRows { return rows }
            } else {
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Picks the delimiter that splits the first lines into a consistent number of columns.
    public static func sniffDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        let lines = text.split(whereSeparator: \.isNewline).prefix(10)
        guard !lines.isEmpty else { return "," }

        var best: (delimiter: Character, score: Int) = (",", 0)
        for candidate in candidates {
            let counts = lines.map { countOutsideQuotes(candidate, in: $0) }
            guard let first = counts.first, first > 0 else { continue }
            let consistent = counts.allSatisfy { $0 == first }
            let score = (consistent ? 1000 : 0) + first
            if score > best.score {
                best = (candidate, score)
            }
        }
        return best.delimiter
    }

    private static func countOutsideQuotes(_ delimiter: Character, in line: Substring) -> Int {
        var count = 0
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == delimiter && !inQuotes {
                count += 1
            }
        }
        return count
    }
}
