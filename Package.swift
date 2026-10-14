// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuickPeek",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "QuickPeekCore", targets: ["QuickPeekCore"]),
        .library(name: "QuickPeekMedia", targets: ["QuickPeekMedia"]),
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
