// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickPeek",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuickPeekCore", targets: ["QuickPeekCore"]),
    ],
    targets: [
        .target(
            name: "QuickPeekCore",
            path: "Sources/QuickPeekCore"
        ),
        .testTarget(
            name: "QuickPeekCoreTests",
            dependencies: ["QuickPeekCore"],
            path: "Tests/QuickPeekCoreTests"
        ),
    ]
)
