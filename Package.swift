// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuickPeek",
    platforms: [.macOS(.v26)],
    products: [
        // One dynamic framework for the app and its extensions, so the shared code is
        // shipped once instead of being linked into every executable.
        .library(
            name: "QuickPeekKit",
            type: .dynamic,
            targets: ["QuickPeekCore", "QuickPeekMedia", "QuickPeekFormats", "QuickPeekText", "QuickPeekInfo"]
        ),
        .library(name: "QuickPeekCore", targets: ["QuickPeekCore"]),
        .library(name: "QuickPeekMedia", targets: ["QuickPeekMedia"]),
        .library(name: "QuickPeekFormats", targets: ["QuickPeekFormats"]),
        .library(name: "QuickPeekText", targets: ["QuickPeekText"]),
        .library(name: "QuickPeekInfo", targets: ["QuickPeekInfo"]),
    ],
    targets: [
        .target(
            name: "QuickPeekCore",
            path: "Sources/QuickPeekCore"
        ),
        .target(
            name: "QuickPeekMedia",
            path: "Sources/QuickPeekMedia"
        ),
        // macOS ships libarchive and its link stub in the SDK, but no header; the module map in
        // Sources/CArchive declares the handful of stable libarchive 3 functions QuickPeek calls.
        .systemLibrary(
            name: "CArchive",
            path: "Sources/CArchive"
        ),
        .target(
            name: "QuickPeekFormats",
            dependencies: ["CArchive"],
            path: "Sources/QuickPeekFormats"
        ),
        .target(
            name: "QuickPeekText",
            dependencies: ["QuickPeekCore"],
            path: "Sources/QuickPeekText"
        ),
        .target(
            name: "QuickPeekInfo",
            dependencies: ["QuickPeekCore", "QuickPeekFormats", "QuickPeekMedia"],
            path: "Sources/QuickPeekInfo"
        ),
        .testTarget(
            name: "QuickPeekInfoTests",
            dependencies: ["QuickPeekInfo"],
            path: "Tests/QuickPeekInfoTests"
        ),
        .testTarget(
            name: "QuickPeekTextTests",
            dependencies: ["QuickPeekText"],
            path: "Tests/QuickPeekTextTests"
        ),
        .testTarget(
            name: "QuickPeekFormatsTests",
            dependencies: ["QuickPeekFormats"],
            path: "Tests/QuickPeekFormatsTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QuickPeekCoreTests",
            dependencies: ["QuickPeekCore"],
            path: "Tests/QuickPeekCoreTests"
        ),
        .testTarget(
            name: "QuickPeekMediaTests",
            dependencies: ["QuickPeekMedia"],
            path: "Tests/QuickPeekMediaTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
