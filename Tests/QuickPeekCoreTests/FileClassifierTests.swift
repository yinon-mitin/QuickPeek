import Testing
@testable import QuickPeekCore

@Suite("FileClassifier")
struct FileClassifierTests {
    @Test("Config and source files map to a highlight.js language", arguments: [
        ("config.yaml", "yaml"),
        ("compose.yml", "yaml"),
        ("package.json", "json"),
        ("Cargo.toml", "ini"),
        ("main.swift", "swift"),
        ("script.py", "python"),
        ("deploy.sh", "bash"),
        ("index.ts", "typescript"),
        ("Dockerfile", "dockerfile"),
        ("Makefile", "makefile"),
        (".env", "bash"),
        (".gitignore", "bash"),
        ("nginx.conf", "nginx"),
        ("STYLE.CSS", "css"),
    ])
    func codeByName(fileName: String, language: String) {
        #expect(FileClassifier.classify(fileName: fileName, prefix: nil) == .code(language: language))
    }

    @Test("Shebang decides the language of an extension-less script")
    func shebang() {
        let kind = FileClassifier.classify(fileName: "run", prefix: "#!/usr/bin/env python3\nprint(1)\n")
        #expect(kind == .code(language: "python"))
        #expect(FileClassifier.classify(fileName: "build", prefix: "#!/bin/zsh\n") == .code(language: "bash"))
    }

    @Test("Documents, tables and media", arguments: [
        ("README.md", FileKind.markdown),
        ("notes.markdown", .markdown),
        ("data.csv", .table(delimiter: nil)),
        ("data.tsv", .table(delimiter: "\t")),
        ("analysis.ipynb", .notebook),
        ("bundle.zip", .archive),
        ("backup.tar.gz", .archive),
        ("photo.webp", .image),
        ("clip.webm", .video),
    ])
    func documents(fileName: String, kind: FileKind) {
        #expect(FileClassifier.classify(fileName: fileName, prefix: nil) == kind)
    }

    @Test("Unknown files fall back to plain text")
    func fallback() {
        #expect(FileClassifier.classify(fileName: "LICENSE", prefix: "MIT License") == .plainText)
        #expect(FileClassifier.classify(fileName: "data.xyz", prefix: nil) == .plainText)
    }
}
