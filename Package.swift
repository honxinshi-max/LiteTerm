// swift-tools-version: 6.0
import Foundation
import PackageDescription

var packageTargets: [Target] = [
    .target(
        name: "LiteSpacePythonBridge",
        path: "LiteSpacePythonBridge",
        publicHeadersPath: "include"
    ),
    .target(
        name: "LiteSpaceCore",
        resources: [.process("Resources/PrivacyInfo.xcprivacy")]
    ),
    .target(
        name: "LiteSpaceWorkspaceSupport",
        dependencies: [
            "LiteSpaceCore",
            "LiteSpacePythonBridge",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
        ],
        path: "LiteSpace/Features/Workspace",
        exclude: [
            "CodeEditorScreen.swift",
            "WorkspaceBottomDrawer.swift",
            "WorkspaceFileBrowser.swift",
            "WorkspacePortsPanel.swift",
            "WorkspacePreview.swift",
            "WorkspaceProblemsPanel.swift",
            "WorkspaceScreen.swift"
        ],
        sources: [
            "WorkspaceInventoryService.swift",
            "WorkspaceSnapshotService.swift",
            "WorkspaceProfileStore.swift",
            "WorkspaceRuntimeProtocol.swift",
            "WorkspacePresentation.swift",
            "WorkspaceController.swift",
            "Runtime/PreviewRequest.swift",
            "Runtime/PreviewResponse.swift",
            "Runtime/LoopbackHTTPHandler.swift",
            "Runtime/LoopbackPreviewServer.swift",
            "Runtime/HealthProbe.swift",
            "Runtime/WebWorkspaceRunner.swift",
            "Runtime/WebSmokeWebView.swift",
            "Runtime/WebErrorBridge.swift",
            "Runtime/SwiftWorkspaceAdvisor.swift",
            "Runtime/PythonRuntimeConfiguration.swift",
            "Runtime/PythonProblemMapper.swift",
            "Runtime/PythonRunDisposition.swift",
            "Runtime/PythonWorkspaceRunner.swift",
            "Runtime/PythonWSGIAdapter.swift"
        ]
    ),
    .executableTarget(
        name: "LiteSpaceCoreTestRunner",
        dependencies: ["LiteSpaceCore", "LiteSpacePythonBridge", "LiteSpaceWorkspaceSupport"],
        path: "Tests/TestRunner"
    )
]

if ProcessInfo.processInfo.environment["LITESPACE_ENABLE_SWIFTPM_XCTESTS"] == "1" {
    packageTargets.append(
        .testTarget(
            name: "LiteSpaceCoreTests",
            dependencies: ["LiteSpaceCore"]
        )
    )
}

let package = Package(
    name: "LiteSpace",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LiteSpaceCore", targets: ["LiteSpaceCore"])
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
