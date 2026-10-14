import Foundation

/// Turns file bytes into text, or returns `nil` when the bytes look binary.
public enum TextDecoder {
    /// The text and a human-readable name of the encoding it was decoded from.
    public static func detect(_ data: Data) -> (text: String, encoding: String)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), "UTF-8 with BOM")
        }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data, encoding: .utf16) {
            return (text, "UTF-16 LE with BOM")
        }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return (text, "UTF-16 BE with BOM")
        }
        if data.prefix(binarySniffLength).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8") }
        return String(data: data, encoding: .windowsCP1252).map { ($0, "Windows-1252") }
    }

    private static let binarySniffLength = 8000

    /// - Parameter truncated: the data was cut at a byte limit, so a trailing partial UTF-8 character is expected.
    public static func decode(_ data: Data, truncated: Bool = false) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.prefix(binarySniffLength).contains(0) {
            return nil
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // A byte cut mid-character at a truncation boundary should not demote the whole file.
        for trim in 1...3 where truncated && data.count > trim {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                return text
            }
        }
        return String(data: data, encoding: .windowsCP1252)
    }
}
