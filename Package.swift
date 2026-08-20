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
    swiftVaultDependencies.append(
        .target(name: "Tink", condition: .when(platforms: [.iOS]))
    )
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
    ),
    .target(
        name: "SwiftWebviewBridge",
        path: "Sources/SwiftWebviewBridge",
        resources: [
            .copy("Resources/bridge")
        ]
    ),
    .testTarget(
        name: "SwiftWebviewBridgeTests",
        dependencies: ["SwiftWebviewBridge"],
        path: "Tests/SwiftWebviewBridgeTests"
    ),
    .target(
        name: "SwiftDappConnect",
        path: "Sources/SwiftDappConnect",
        resources: [
            // 注意：不能 .copy("Resources")（会在 bundle 内生成 Resources/ 包装层，
            // 本工具链 codesign 报 "bundle format unrecognized"）；直接复制文件到 bundle 根。
            .copy("Resources/ccdao-eip1193-provider-ios.js")
        ]
    ),
    .testTarget(
        name: "SwiftDappConnectTests",
        dependencies: ["SwiftDappConnect"],
        path: "Tests/SwiftDappConnectTests"
    ),
    .target(
        name: "SwiftWallet",
        dependencies: [
            .target(name: "SwiftWebviewBridge"),
            // WalletSigning 协议定义在 SwiftDappConnect；SwiftWallet 作为其真实实现。
            .target(name: "SwiftDappConnect")
        ],
        path: "Sources/SwiftWallet"
    ),
    .testTarget(
        name: "SwiftWalletTests",
        dependencies: ["SwiftWallet"],
        path: "Tests/SwiftWalletTests"
    ),
    .target(
        name: "SwiftNft",
        dependencies: [
            // 仅取 WalletAccount / ChainType 模型（SwiftDappConnect 零运行时依赖，对应 Kotlin :core）。
            .target(name: "SwiftDappConnect"),
            // Room → GRDB（四表：nft_meta / swtc_nfts / evm_nft_items / evm_nft_collections，见 Nft-Swift 02 §5）。
            .product(name: "GRDB", package: "GRDB.swift")
        ],
        path: "Sources/SwiftNft"
    ),
    .testTarget(
        name: "SwiftNftTests",
        dependencies: [
            "SwiftNft",
            .target(name: "SwiftDappConnect"), // 测试用 WalletAccount/ChainType
            .product(name: "GRDB", package: "GRDB.swift") // 测试用内存 DatabasePool
        ],
        path: "Tests/SwiftNftTests",
        resources: [
            .copy("Fixtures") // 真实 DID/NFT 数据（RealDidDataTests 用，见 Fixtures/）
        ]
    ),
    .target(
        name: "SwiftDid",
        dependencies: [
            .target(name: "SwiftWebviewBridge"), // did-bridge.html / did-bridge.js 资产 + 桥运行时
            .target(name: "SwiftDappConnect"), // DidSDK 协议 / WalletAccount / ChainType
            .target(name: "SwiftNft"), // 阶段二：DTO 与 DidNftResolution 协议缝归 SwiftNft（见 Nft-Swift 02 §2）
            .product(name: "GRDB", package: "GRDB.swift") // 对应 Kotlin Room（did_documents / did_pending）
        ],
        path: "Sources/SwiftDid"
    ),
    .testTarget(
        name: "SwiftDidTests",
        dependencies: [
            "SwiftDid",
            .target(name: "SwiftDappConnect"),
            .product(name: "GRDB", package: "GRDB.swift")
        ],
        path: "Tests/SwiftDidTests",
        resources: [
            .copy("Fixtures") // 真实 DID 文档（RealDidDocumentTests 用，见 Fixtures/）
        ]
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
        ),
        .library(
            name: "SwiftWebviewBridge",
            targets: ["SwiftWebviewBridge"]
        ),
        .library(
            name: "SwiftDappConnect",
            targets: ["SwiftDappConnect"]
        ),
        .library(
            name: "SwiftWallet",
            targets: ["SwiftWallet"]
        ),
        .library(
            name: "SwiftNft",
            targets: ["SwiftNft"]
        ),
        .library(
            name: "SwiftDid",
            targets: ["SwiftDid"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/tmthecoder/Argon2Swift.git", branch: "main"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.56.0"),
        // 对应 Kotlin :nft 的 Room（room-runtime / room-ktx）。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: targets
)
