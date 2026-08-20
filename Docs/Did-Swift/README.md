# DID · Swift 移植设计稿

本文档是 `kotlin-toolkits` 中 `:did` 模块的 Swift 版本设计。目标是把 Kotlin 版「DID 文档管理、Profile/头像、NFT 凭证（VC）签发与验证、VCID 绑定、IPFS 签名」能力以 Swift/iOS 惯用方式复刻，并作为 `SwiftDappConnect` 的 `DidSDK` 实现。

> 状态：**已实现落库**（`Sources/SwiftDid/`，commit `4291b3a` 起；对齐 `kotlin-toolkits` 源码，2026-08）。设计稿按 Kotlin 源码逐项对齐，实现级补充与偏离见 04 §5（实现回写表）。

## 设计原则

1. **复用 SwiftWebviewBridge 资产与桥协议，但自持独立 runtime**：Kotlin `:did` 的 `AndroidDidWebRuntime` 依赖 `:webview-bridge` 的 `did-bridge.html`；Swift 侧复用 `SwiftWebviewBridge` 内置的 `did-bridge.html` / `did-bridge.js` / `did-0.3.2.min.js` 与 PromiseBridge 协议，但 **SwiftDid 自持一个 `WebviewBridgeClient` 实例**加载 did-bridge（`WebviewBridgeEngine.shared` 已被 SwiftWallet 的 wallet-bridge 占用，单例只能承载一个页面），本模块做**类型化封装 + 服务编排**，不重复造桥。
2. **存储用 GRDB 替代 Room**：Kotlin 的 Room 无原生 Swift 等价，方案采用 [GRDB.swift](https://github.com/groue/GRDB.swift)（Swift 生态的 Room 等价物，`from: "7.0.0"`）：`DidStore` 协议 + `GRDBDidStore` 实现（`did_documents` 表 + ValueObservation 观察），宿主可替换。
3. **Swift 化 API**：`suspend` → `async throws`，`Flow` → `AsyncStream`，`JSONObject` → `[String: Any]`/`Codable`，Gson → `JSONDecoder`。
4. **avatar/NFT 经 `SwiftNft` 模块接入（已实现）**：Kotlin 的 avatar 解析依赖独立 `:nft` 模块（`NftSdk`），Swift 侧 **`SwiftNft` 已落库**，`SwiftDid` 以**可选依赖**接入（对齐 Kotlin `nftSdk: NftSdk? = null`，构造参数 `nft: (any DidNftResolution)?`）。头像解析回退链与 Kotlin 一致：`DidAvatarResolver`（宿主注入）→ `SwiftNft` → 本地兜底解析；未注入时相关方法返回 nil，协议缝保证宿主无 SwiftNft 也能编译。
5. **对接 SwiftDappConnect**：实现 `DidSDK` 协议（`didGenerateBase58PublicKey` / `signCredentialForDApp` / `ipfsPersonalSign` / `ipfsGetPublicKey`），成为中间件 `did_*` / `ipfs_*` 方法的真实后端（demo 目前是桩）。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-kotlin-architecture.md](01-kotlin-architecture.md) | Kotlin 版模块解析：DidSdk 全量 API、模型、端口（IDidBridge/IDidResolver/IDidStore）、Room 存储、桥方法清单与测试基线 |
| [02-swift-design.md](02-swift-design.md) | Swift 版设计：模块布局、模型、`SwiftDid` 代码草案、存储协议、并发与安全要点 |
| [03-protocol-and-js.md](03-protocol-and-js.md) | did-bridge.js 方法协议、与 Kotlin 差异、**IPFS 网关保持硬编码（D5 接受，不做注入）**、密钥经桥安全 |
| [04-migration-and-testing.md](04-migration-and-testing.md) | Kotlin → Swift 逐项对照、实现坑（存储/Room、keccak、头像依赖）、测试策略与实施清单 |

## 快速接入

```swift
import SwiftDid
import SwiftNft
import GRDB

// 存储：GRDB（对应 Kotlin Room）
let db = try DatabasePool(path: ".../did.sqlite")
let did = try SwiftDid(store: GRDBDidStore(database: db))  // nft: 可选，接入 SwiftNft 后启用头像解析

// 头像解析后端（可选）：SwiftNft 随包默认解析器 + 宿主注入的 SWTC/EVM 解析器
let nft = try SwiftNft(config: SwiftNftConfig(
    store: GRDBNftStore(database: DatabasePool(path: ".../nft.sqlite")),
    ethTokenUriResolver: EthTokenUriResolver(getRpcNode: { chainId in
        chainId == 1 ? "https://ethereum-rpc.publicnode.com" : nil
    }),
    swtcTokenUriResolver: SwtcTokenUriResolver(getRpcNode: { "https://srje115qd43qw2.swtc.top" })
))
let did2 = try SwiftDid(store: GRDBDidStore(database: db), nft: nft)

// DApp 签名面（SwiftDappConnect.DidSDK）
let signing: any DidSDK = did

// 直接能力
let base58 = try await did.didGenerateBase58PublicKey(privateKey: "0x...")
let vc = try await did.signCredentialForDApp(privateKey: "0x...", vcJson: payload)
let signature = try await did.ipfsPersonalSign(privateKey: "0x...", data: bytes)
```

## 与 Kotlin 差异一览

| 维度 | Kotlin | Swift |
| --- | --- | --- |
| runtime | `AndroidDidWebRuntime`（隐藏 WebView） | `SwiftDid` 自持 `WebviewBridgeClient` 加载 did-bridge 资产（独立隐藏 WebView，对齐 Kotlin） |
| 存储 | Room（`DidRoomDatabase`） | **GRDB**（`GRDBDidStore`，Swift 生态的 Room 等价物） |
| 观察 | `Flow<DidEntity?>` | `AsyncStream<DidEntity?>`（GRDB ValueObservation 驱动） |
| 头像/NFT | 内置 `:nft` 模块依赖 | **`SwiftNft`（已实现）可选接入**（`nft: (any DidNftResolution)?`）+ `DidAvatarResolver` 宿主注入；DTO 与 `DidNftResolution` 协议缝已迁入 SwiftNft（防依赖环，见 Nft-Swift 02 §2） |
| EIP-55 checksum | `ChecksumUtils` | keccak-256（**首选专门轻量依赖**；确需自实现则与 BouncyCastle KAT 全量交叉验证） |
| DApp 对接 | 被 DApp 层直接调用 | 实现 `SwiftDappConnect.DidSDK` 注入中间件 |

## 关键设计点

- **零 JS 改动（网关保持硬编码）**：复用现有 `did-bridge.js`，其硬编码的 IPFS 网关 `https://wodecards.wh.jccdex.cn:8550` **保持原样、不做注入**（`EngineDidBridge` 直接用 SwiftWebviewBridge 默认 bundle 加载，见 03 §3）；`security-review.md` D5 为已知接受项，与 Kotlin `:did` 现状一致。
- **SwiftDid 自持 DID 隐藏 WebView（不复用共享引擎）**：`WebviewBridgeEngine.shared` 一个 client 只能承载一个 bridge 页面（已被 SwiftWallet 占用）；SwiftDid 自持 `WebviewBridgeClient` 加载 `did-bridge.html`，与 Kotlin 的独立 WebView 对齐（详见 02 §1/§3）。
- **模型镜像**：`Did` / `Profile` / `Nft` / `ProfileVC` / `VerificationMethod` / `DidEntity` / 凭证模型等与 Kotlin 数据类一一对应。
- **写操作链**：`publishDid` + `didStat`（previousCid）+ `resolveBaseDoc` 的编排逻辑保留在 Swift 服务层（`DidCoreService` 等价，**含 pending 对账状态机**，见 01 §6），桥只做方法透传。**Swift 增强：pending 表持久化到 GRDB**，消除 Kotlin 内存态的重启丢失窗口。
- **安全注意**：`signCredentialForDApp` 只做结构校验（对齐 Kotlin M-15 三条），用户确认由宿主 UI 完成；私钥经 JS 桥传输的内存边界同 `SwiftWallet`。
- **范围（一期已实现）**：`DidSyncService`（多 DID 批量同步）一期裁剪、二期补；NFT 元数据 DTO 与 `DidNftResolution` 协议缝已从 SwiftDid **迁入 SwiftNft**（阶段二，SwiftDid 依赖 SwiftNft），SwiftDid 以 `public typealias` 保持公开 API 拼写。
