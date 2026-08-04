// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let vendoredTinkPath = "Vendor/Tink/Tink.xcframework"
let hasVendoredTink = FileManager.default.fileExists(atPath: vendoredTinkPath)

var swiftVaultDependencies: [Target.Dependency] = [
    .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    .product(name: "Argon2Swift", package: "Argon2Swift")
]

if hasVendoredTink {
    swiftVaultDependencies.append("Tink")
}

var targets: [Target] = [
    .target(
        name: "SwiftVault",
        dependencies: swiftVaultDependencies,
        path: "Sources/SwiftVault",
        resources: [
            .copy("swift-protobuf-config.json")
        ],
        plugins: [
            .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")
        ]
    ),
    .testTarget(
        name: "SwiftVaultTests",
        dependencies: ["SwiftVault"],
        path: "Tests/SwiftVaultTests"
    )
]

if hasVendoredTink {
    targets.insert(
        .binaryTarget(
            name: "Tink",
            path: vendoredTinkPath
        ),
        at: 0
    )
}

let package = Package(
    name: "swift-toolkits",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SwiftVault",
            targets: ["SwiftVault"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/tmthecoder/Argon2Swift.git", branch: "main"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.56.0")
    ],
    targets: targets
)
