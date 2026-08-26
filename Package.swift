// swift-tools-version: 6.0
import Foundation
import PackageDescription

var packageTargets: [Target] = [
    .target(
        name: "LiteTermCore",
        resources: [.process("Resources/PrivacyInfo.xcprivacy")]
    ),
    .target(
        name: "LiteTermWorkspaceSupport",
        dependencies: [
            "LiteTermCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
        ],
        path: "LiteTerm/Features/Workspace",
        sources: [
            "WorkspaceInventoryService.swift",
            "WorkspaceSnapshotService.swift",
            "WorkspaceProfileStore.swift",
            "Runtime/PreviewRequest.swift",
            "Runtime/PreviewResponse.swift",
            "Runtime/LoopbackHTTPHandler.swift",
            "Runtime/LoopbackPreviewServer.swift",
            "Runtime/HealthProbe.swift"
        ]
    ),
    .executableTarget(
        name: "LiteTermCoreTestRunner",
        dependencies: ["LiteTermCore", "LiteTermWorkspaceSupport"],
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
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            revision: "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-transport-services.git",
            revision: "67787bb645a5e67d2edcdfbe48a216cc549222d5"
        )
    ],
    targets: packageTargets
)
