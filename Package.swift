// swift-tools-version: 6.0
import Foundation
import PackageDescription

var packageTargets: [Target] = [
    .target(
        name: "LiteTermCore",
        resources: [.process("Resources/PrivacyInfo.xcprivacy")]
    ),
    .executableTarget(
        name: "LiteTermCoreTestRunner",
        dependencies: ["LiteTermCore"],
        path: "Tests/TestRunner"
    )
]

if ProcessInfo.processInfo.environment["LITETERM_ENABLE_SWIFTPM_XCTESTS"] == "1" {
    packageTargets.append(
        .testTarget(
            name: "LiteTermCoreTests",
            dependencies: ["LiteTermCore"]
        )
    )
}

let package = Package(
    name: "LiteTerm",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LiteTermCore", targets: ["LiteTermCore"])
    ],
    targets: packageTargets
)
