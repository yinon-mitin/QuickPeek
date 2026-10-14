import Foundation

/// Turns file bytes into text, or returns `nil` when the bytes look binary.
public enum TextDecoder {
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
