// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteTermSSHIntegrationTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "LiteTerm", path: "../.."),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            revision: "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssh.git",
            revision: "3ec281496f28a3b6581afd946b759e2642f5cd8d"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-transport-services.git",
            revision: "67787bb645a5e67d2edcdfbe48a216cc549222d5"
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            revision: "47d3869a7291f085c1fb9fb1e6d3b97a793f45c6"
        )
    ],
    targets: [
        .executableTarget(
            name: "LiteTermSSHIntegrationTestRunner",
            dependencies: [
                .product(name: "LiteTermCore", package: "LiteTerm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services"
                ),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: ".",
            exclude: ["Package.swift", "Package.resolved"]
        )
    ]
)
