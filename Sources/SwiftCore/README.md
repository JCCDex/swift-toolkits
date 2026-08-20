# SwiftCore

`kotlin-toolkits` 中 `:core` 模块的 Swift 移植：跨模块共享的领域模型（`ChainType` / `Path` / `WalletAccount`）。SwiftDappConnect（原 `WalletAccount`/`ChainType`/`Path` 定义处）、SwiftWallet（原 `Path` 重复定义处）、SwiftNft、SwiftDid、SwiftAccount 共享同一模型来源，消除跨模块重复（`fromBip44Code`/`label` 补充见 [Docs/Account-Swift/04-migration-and-testing.md](../Docs/Account-Swift/04-migration-and-testing.md) 坑 #12/#13）。

## 模型

```swift
public enum ChainType: String, CaseIterable, Sendable {
    case eth, bsc, polygon, arb1, base, swtc, moac

    public var bip44Code: Int64        // BIP44 链码（eth = 2147483708 …）
    public var label: String           // 展示名（"Ethereum" / "SWTC" …）
    public var evmChainId: Int64?      // EVM chainId（swtc = nil）
    public var isEvm: Bool             // 除 swtc 外均为 true
    public var isSwtc: Bool
    public static func fromBip44Code(_ code: Int64) -> ChainType?
}

public struct Path: Codable, Sendable, Equatable {
    public let chain: Int64            // BIP44 链码
    public let account: Int
    public let change: Int
    public let index: Int

    public var isRoot: Bool            // account == 0 && change == 0 && index == 0
    public var derivationPath: String  // m/44'/<chain>'/<account>'/<change>/<index>
    public static func root(chainType: ChainType) -> Path
}

public struct WalletAccount: Sendable, Identifiable, Equatable {
    public let id: String              // 默认 UUID；判重依赖 address（导入入口先按地址预检）
    public let address: String
    public let chain: ChainType
    public let name: String
    public let isHD: Bool
    public let parentId: String?
    public let path: Path?
    public let publicKey: String

    public var isRootHD: Bool          // isHD && path.isRoot && parentId == nil
}
```

> `WalletAccount` 只含元数据，不含私钥——私钥在 SwiftVault 中，地址/链/路径是关联键。

## 快速开始

```swift
import SwiftCore

let chain = ChainType.eth                       // bip44Code = 2_147_483_708
let path = Path.root(chainType: chain)          // m/44'/2147483708'/0'/0/0
let account = WalletAccount(
    address: "0xabc…",
    chain: .eth,
    name: "Demo Wallet",
    isHD: false
)
```

## 设计说明

- 全部模型 `Sendable + Equatable`（`WalletAccount` 额外 `Identifiable`），可跨 actor 自由传递。
- `Path` 合并了 SwiftWallet 侧的 `derivationPath`（Kotlin `Path.toString()`）与 `Codable`，`isRoot`/`root(chainType:)` 对齐 Kotlin core。
- 中间件过滤「HD 根账户」请用 `isHD && parentId == nil`（不查 `path`），勿混用 `isRootHD`（后者语义更严：还要求 `path.isRoot`）。
