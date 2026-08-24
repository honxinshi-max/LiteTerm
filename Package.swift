// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteTerm",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LiteTermCore", targets: ["LiteTermCore"])
    ],
    targets: [
        .target(name: "LiteTermCore"),
        .executableTarget(
            name: "LiteTermCoreTestRunner",
            dependencies: ["LiteTermCore"],
            path: "Tests/TestRunner"
        ),
        .target(
            name: "XCTest",
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "LiteTermCoreTests",
            dependencies: ["LiteTermCore", "XCTest"]
        )
    ]
)
