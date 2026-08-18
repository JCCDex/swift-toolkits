# 02 · Swift 版设计

## 1. 模块布局

```text
Sources/SwiftWallet/
├── SwiftWallet.swift        // @MainActor 单例入口：生命周期 + 类型化方法（薄封装 SwiftWebviewBridge）
├── Model/WalletModels.swift // Keypair / Path / Mnemonic / SubWallet / GenerateHDWalletResult / TraditionalDeriveResult
└── (无自有 JS 资源：复用 SwiftWebviewBridge bundle 内的 wallet-bridge.html 与钱包 JS 库)
```

`Package.swift` 依赖：

```swift
.target(
    name: "SwiftWallet",
    dependencies: [
        .product(name: "SwiftWebviewBridge", package: "swift-toolkits")
    ],
    path: "Sources/SwiftWallet"
)
```

## 2. 模型（镜像 Kotlin 数据类，Decodable）

```swift
public struct Keypair: Codable, Sendable, Equatable {
    public let privateKey: String
    public let publicKey: String
}

public struct Path: Codable, Sendable, Equatable {
    public let chain: Int64
    public let account: Int
    public let change: Int
    public let index: Int

    public var derivationPath: String { "m/44'/\(chain)'/\(account)'/\(change)/\(index)" }
}

public struct Mnemonic: Codable, Sendable, Equatable {
    public let value: String
    public let language: String
}

public struct SubWallet: Codable, Sendable, Equatable {
    public let chain: Int64
    public let address: String
    public let path: Path
    public let keypair: Keypair
}

public struct GenerateHDWalletResult: Codable, Sendable, Equatable {
    public let mnemonic: String
    public let address: String
    public let language: String
    public let keypair: Keypair
    public let accounts: [SubWallet]
}

public struct TraditionalDeriveResult: Codable, Sendable, Equatable {
    public let address: String
    public let keypair: Keypair
    public let mnemonic: Mnemonic?
    public let secret: String?
    public let path: Path?
    public let sourcePrivateKey: String?
}
```

## 3. SwiftWallet（代码草案）

```swift
import Foundation
import SwiftWebviewBridge

/// Kotlin `object WalletSdk` 的 Swift 版：隐藏 WebView 钱包桥的类型化封装。
@MainActor
public final class SwiftWallet {
    public static let shared = SwiftWallet()

    private let engine = WebviewBridgeEngine.shared
    private var started = false

    private init() {}

    // MARK: - 生命周期

    /// 幂等：初始化并启动隐藏 WebView（加载 wallet-bridge.html）。
    public func start() throws {
        guard !self.started else { return }
        self.engine.initialize(config: WebviewBridgeConfig.bridge(named: "wallet-bridge"))
        try self.engine.start()
        self.started = true
    }

    public func destroy() {
        self.engine.destroy()
        self.started = false
    }

    // MARK: - 助记词 / 派生

    public func validateMnemonic(_ mnemonic: String, language: String = "english") async throws -> Bool {
        try await self.call(method: "validateMnemonic", params: ["mnemonic": mnemonic, "language": language]).toBool()
    }

    public func generateMnemonic(length: Int = 128, language: String = "english") async throws -> Mnemonic {
        try await self.callAs(method: "generateMnemonic", params: ["length": length, "language": language])
    }

    public func deriveChild(
        mnemonic: String, chain: Int64,
        account: Int = 0, change: Int = 0, index: Int = 0,
        language: String = "english"
    ) async throws -> SubWallet {
        try await self.callAs(method: "deriveChild", params: [
            "mnemonic": mnemonic, "chain": chain,
            "account": account, "change": change, "index": index,
            "language": language,
        ])
    }

    public func hdWalletFromMnemonic(
        mnemonic: String, chains: [Int64] = [], language: String = "english"
    ) async throws -> GenerateHDWalletResult {
        try await self.callAs(method: "hdWalletFromMnemonic", params: [
            "mnemonic": mnemonic, "chains": chains, "language": language,
        ])
    }

    public func deriveFromMnemonic(
        mnemonic: String, chain: Int64,
        account: Int = 0, change: Int = 0, index: Int = 0,
        language: String = "english"
    ) async throws -> TraditionalDeriveResult { ... }

    public func deriveFromPrivateKey(privateKey: String, chain: Int64) async throws -> TraditionalDeriveResult { ... }

    public func validatePrivateKey(_ privateKey: String, chain: Int64) async throws -> Bool { ... }

    // MARK: - SWTC 交易

    public func buildSwtcPayment(address: String, amount: String, to: String, token: String, memo: String) async throws -> String { ... }
    public func buildSwtcNftTransfer(address: String, to: String, tokenId: String, memo: String) async throws -> String { ... }
    public func isValidAddress(_ address: String) async throws -> Bool { ... }
    public func signSwtcTransaction(tx: [String: Any], secret: String) async throws -> String { ... }
    public func signMessage(address: String, message: String, secret: String) async throws -> String { ... }
    public func signTransaction(tx: [String: Any], secret: String) async throws -> String { ... }
    public func multiSign(tx: [String: Any], secret: String) async throws -> String { ... }

    // MARK: - EVM 签名

    public func personalSign(privateKey: String, data: String) async throws -> String { ... }
    public func signTypedData(privateKey: String, data: String, version: String) async throws -> String { ... }
    public func recoverTypedSignature(data: String, signature: String, version: String) async throws -> String { ... }
    public func recoverPersonalSignature(data: String, signature: String) async throws -> String { ... }
    public func getEncryptionPublicKey(privateKey: String) async throws -> String { ... }
    public func decrypt(privateKey: String, data: String) async throws -> String { ... }
    public func signEthTransaction(privateKey: String, tx: [String: Any]) async throws -> String { ... }

    // MARK: - 私有

    private func ensureStarted() throws {
        guard self.started else { throw SwiftWalletError.notInitialized }
    }

    private func call(method: String, params: [String: Any]?) async throws -> String {
        try self.ensureStarted()
        return try await self.engine.callJsMethod(method: method, params: params)
    }

    private func callAs<T: Decodable>(method: String, params: [String: Any]?) async throws -> T {
        try self.ensureStarted()
        return try await self.engine.callJsMethodAs(method: method, params: params, as: T.self)
    }
}

public enum SwiftWalletError: Error, Equatable {
    case notInitialized
}
```

> 说明：`callJsMethodAs` 走 `[String: Any]` 参数重载即可（`Encodable` 重载由底层转为字典，行为一致）。`chain` 用 `Int64` 与 `SwiftDappConnect.ChainType.bip44Code` 数值一致。

## 4. 对接 SwiftDappConnect

`SwiftWallet` 实现 `WalletSigning`（`MiddlewareInterfaces.swift`），作为中间件的真实签名后端：

```swift
extension SwiftWallet: WalletSigning {
    public func personalSign(privateKey: String, message: String) async throws -> String {
        try await self.personalSign(privateKey: privateKey, data: message)
    }
    public func signTypedData(privateKey: String, typedData: String, version: String) async throws -> String {
        try await self.signTypedData(privateKey: privateKey, data: typedData, version: version)
    }
    public func signEthTransaction(privateKey: String, txParams: [String: Any]) async throws -> String {
        try await self.signEthTransaction(privateKey: privateKey, tx: txParams)
    }
    // ... signSwtcTransaction / multiSign / signMessage / decrypt /
    //     getEncryptionPublicKey / recover* / buildSwtcNftTransfer 逐一转发
}
```

接线（宿主）：

```swift
let eth = DAppConnectSdk.createEthMiddleware(
    accountProvider: accounts,
    secretProvider: secrets,          // SwiftVault 实现
    nodeProvider: nodes,
    signing: SwiftWallet.shared       // 替代 demo 桩
)
```

## 5. 并发与安全要点

- **@MainActor**：`SwiftWallet` 与 `WebviewBridgeEngine` 同为主线程隔离，桥调用天然串行；JS 回包经网关超时任务兜底（30s）。
- **密钥 String 传输**：私钥/助记词以 `String` 跨桥传输（同 Kotlin 现状）。调用方拿到返回后应尽快处理；如需强化，可评估「经桥加密通道回传 Data」的后续方案。
- **未初始化抛错**：`start()` 前调用任意方法抛 `SwiftWalletError.notInitialized`（对齐 Kotlin `bridgeOrThrow`）。
- **密钥不落盘**：本模块无持久化；存储职责在 `SwiftVault`。
