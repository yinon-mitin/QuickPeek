import AppKit

/// Colours for highlight.js scopes, adapting to light and dark mode. Values follow the
/// "github" and "github-dark" highlight.js themes.
public struct CodeTheme: @unchecked Sendable {
    private let colors: [String: NSColor]
    private let backgrounds: [String: NSColor]
    private let bold: Set<String>
    private let italic: Set<String>

    public func color(for scope: String) -> NSColor? {
        lookup(scope, in: colors)
    }

    public func background(for scope: String) -> NSColor? {
        lookup(scope, in: backgrounds)
    }

    /// Text attributes for a scope on top of `font`.
    public func attributes(for scope: String, font: NSFont) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = color(for: scope) { attributes[.foregroundColor] = color }
        if let background = background(for: scope) { attributes[.backgroundColor] = background }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if contains(scope, in: bold) { traits.insert(.bold) }
        if contains(scope, in: italic) { traits.insert(.italic) }
        if !traits.isEmpty {
            attributes[.font] = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        }
        return attributes
    }

    /// "title.function" falls back to "title" when it has no colour of its own.
    private func lookup<Value>(_ scope: String, in table: [String: Value]) -> Value? {
        var candidate = scope
        while true {
            if let value = table[candidate] { return value }
            guard let dot = candidate.lastIndex(of: ".") else { return nil }
            candidate = String(candidate[..<dot])
        }
    }

    private func contains(_ scope: String, in set: Set<String>) -> Bool {
        lookup(scope, in: Dictionary(uniqueKeysWithValues: set.map { ($0, true) })) ?? false
    }

    public static let github: CodeTheme = {
        func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            }
        }
        let keyword = color(0xD73A49, 0xFF7B72)
        let title = color(0x6F42C1, 0xD2A8FF)
        let constant = color(0x005CC5, 0x79C0FF)
        let string = color(0x032F62, 0xA5D6FF)
        let builtIn = color(0xE36209, 0xFFA657)
        let comment = color(0x6A737D, 0x8B949E)
        let tag = color(0x22863A, 0x7EE787)

        var colors: [String: NSColor] = [:]
        for scope in ["keyword", "doctag", "template-tag", "template-variable", "type", "variable.language"] { colors[scope] = keyword }
        for scope in ["title", "title.class", "title.function"] { colors[scope] = title }
        for scope in ["attr", "attribute", "literal", "meta", "number", "operator", "selector-attr", "selector-class", "selector-id", "variable", "section"] {
            colors[scope] = constant
        }
        for scope in ["string", "regexp", "meta.string"] { colors[scope] = string }
        for scope in ["built_in", "symbol"] { colors[scope] = builtIn }
        for scope in ["comment", "code", "formula"] { colors[scope] = comment }
        for scope in ["name", "quote", "selector-pseudo", "selector-tag"] { colors[scope] = tag }
        colors["subst"] = .labelColor
        colors["bullet"] = color(0x735C0F, 0xF2CC60)
        colors["addition"] = color(0x22863A, 0xAFF5B4)
        colors["deletion"] = color(0xB31D28, 0xFFDCD7)

        return CodeTheme(
            colors: colors,
            backgrounds: ["addition": color(0xF0FFF4, 0x033A16), "deletion": color(0xFFEEF0, 0x67060C)],
            bold: ["section", "strong"],
            italic: ["emphasis"]
        )
    }()
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
