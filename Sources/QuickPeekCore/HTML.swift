/// Escaping helpers for building preview documents from untrusted file content.
public enum HTML {
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// A double-quoted JavaScript string literal that is safe to place inside an inline `<script>`.
    public static func javaScriptString(_ text: String) -> String {
        var result = "\""
        result.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "<": result += "\\u003c"
            case ">": result += "\\u003e"
            case "&": result += "\\u0026"
            case "\u{2028}": result += "\\u2028"
            case "\u{2029}": result += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    result += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Keeps a vendored script from terminating its own inline `<script>` element.
    static func inlineScript(_ source: String) -> String {
        source.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }
}
