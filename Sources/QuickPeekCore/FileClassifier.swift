import Foundation

/// Decides a file's `FileKind` from its name and, for extension-less scripts, its first line.
public enum FileClassifier {
    public static func classify(fileName: String, prefix: String?) -> FileKind {
        let name = fileName.lowercased()

        if let kind = exactNames[name] {
            return kind
        }
        if name == ".env" || name.hasPrefix(".env.") {
            return .code(language: "bash")
        }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz") {
            return .archive
        }
        if name.contains("nginx") && name.hasSuffix(".conf") {
            return .code(language: "nginx")
        }

        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let kind = extensions[ext] {
            return kind
        }
        if let prefix, let language = shebangLanguage(prefix) {
            return .code(language: language)
        }
        return .plainText
    }

    /// Maps `#!/usr/bin/env python3` or `#!/bin/zsh` to a highlight.js language.
    static func shebangLanguage(_ text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let firstLine = text.dropFirst(2).prefix { $0 != "\n" }
        var words = firstLine.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        if (words[0] as NSString).lastPathComponent == "env" {
            words.removeFirst()
            words.removeAll { $0.hasPrefix("-") }
        }
        guard let interpreter = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }

        let base = interpreter.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
        switch base {
        case "sh", "bash", "zsh", "ksh", "dash", "fish": return "bash"
        case "python": return "python"
        case "node": return "javascript"
        case "deno", "bun", "ts-node": return "typescript"
        case "ruby": return "ruby"
        case "perl": return "perl"
        case "php": return "php"
        case "lua": return "lua"
        case "swift": return "swift"
        default: return nil
        }
    }

    private static let exactNames: [String: FileKind] = [
        "dockerfile": .code(language: "dockerfile"),
        "containerfile": .code(language: "dockerfile"),
        "makefile": .code(language: "makefile"),
        "gnumakefile": .code(language: "makefile"),
        "cmakelists.txt": .code(language: "cmake"),
        "jenkinsfile": .code(language: "groovy"),
        "gemfile": .code(language: "ruby"),
        "rakefile": .code(language: "ruby"),
        "podfile": .code(language: "ruby"),
        "brewfile": .code(language: "ruby"),
        "vagrantfile": .code(language: "ruby"),
        "procfile": .code(language: "bash"),
        ".gitignore": .code(language: "bash"),
        ".dockerignore": .code(language: "bash"),
        ".npmignore": .code(language: "bash"),
        ".bashrc": .code(language: "bash"),
        ".bash_profile": .code(language: "bash"),
        ".zshrc": .code(language: "bash"),
        ".zprofile": .code(language: "bash"),
        ".profile": .code(language: "bash"),
        ".gitconfig": .code(language: "ini"),
        ".editorconfig": .code(language: "ini"),
        ".npmrc": .code(language: "ini"),
    ]

    private static let extensions: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ language: String, _ exts: String...) {
            for ext in exts { map[ext] = .code(language: language) }
        }
        add("yaml", "yaml", "yml")
        add("json", "json", "jsonc", "json5", "geojson", "har", "webmanifest")
        add("ini", "toml", "ini", "cfg", "conf", "tf", "tfvars", "hcl")
        add("properties", "properties")
        add("xml", "xml", "plist", "xsd", "xsl", "xslt", "csproj", "storyboard", "xib", "html", "htm", "xhtml", "vue", "svelte")
        add("swift", "swift")
        add("python", "py", "pyw", "pyi")
        add("ruby", "rb", "gemspec")
        add("javascript", "js", "mjs", "cjs", "jsx")
        add("typescript", "ts", "tsx", "mts", "cts")
        add("go", "go")
        add("rust", "rs")
        add("c", "c", "h")
        add("cpp", "cc", "cpp", "cxx", "hpp", "hh", "hxx")
        add("objectivec", "m", "mm")
        add("java", "java")
        add("kotlin", "kt", "kts")
        add("csharp", "cs")
        add("php", "php")
        add("perl", "pl", "pm")
        add("lua", "lua")
        add("r", "r")
        add("sql", "sql")
        add("bash", "sh", "bash", "zsh", "ksh", "fish", "command")
        add("powershell", "ps1", "psm1", "psd1")
        add("css", "css")
        add("scss", "scss", "sass")
        add("less", "less")
        add("graphql", "graphql", "gql")
        add("diff", "diff", "patch")
        add("dockerfile", "dockerfile")
        add("makefile", "mk", "mak")
        add("cmake", "cmake")
        add("protobuf", "proto")
        add("scala", "scala", "sbt")
        add("dart", "dart")
        add("elixir", "ex", "exs")
        add("haskell", "hs")
        add("groovy", "groovy", "gradle")
        add("nginx", "nginx")

        for ext in ["md", "markdown", "mdown", "mkd", "mdx"] { map[ext] = .markdown }
        map["csv"] = .table(delimiter: nil)
        map["tsv"] = .table(delimiter: "\t")
        map["tab"] = .table(delimiter: "\t")
        map["ipynb"] = .notebook
        for ext in ["zip", "jar", "tar", "tgz", "tbz2", "txz", "gz"] { map[ext] = .archive }
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "heic", "heif", "bmp", "tif", "tiff", "ico"] {
            map[ext] = .image
        }
        for ext in ["webm", "mkv", "mp4", "m4v", "mov", "avi", "ogv"] { map[ext] = .video }
        return map
    }()
}
