# SwiftDid

`kotlin-toolkits` 中 `:did` 模块的 Swift 移植：DID 文档解析与管理、Profile/头像 VC、NFT 凭证（VC）签发/验证、VCID 绑定、pending 对账（GRDB 持久化）。复用 `SwiftWebviewBridge` 的 did-bridge 资产（隐藏 WebView），经 `SwiftNft` 接入头像/NFT 元数据解析，并实现 `SwiftDappConnect.DidSDK` 作为中间件 `did_*` / `ipfs_*` 方法的真实后端。

## 设计原则

1. **复用桥资产、自持独立 runtime**：复用 `SwiftWebviewBridge` 内置的 `did-bridge.html` / `did-bridge.js` / `did-0.3.2.min.js` 与 PromiseBridge 协议；SwiftDid **自持一个 `WebviewBridgeClient`** 加载 did-bridge（`WebviewBridgeEngine.shared` 已被 SwiftWallet 的 wallet-bridge 占用，单例只能承载一个页面）。
2. **GRDB 替代 Room**：`DidStore` 协议 + `GRDBDidStore` 实现（`did_documents` 表 + `did_pending` 表 + ValueObservation 观察流），宿主可替换。
3. **Swift 化 API**：`suspend` → `async throws`，`Flow` → `AsyncStream`，Gson → `[String: Any]`/Codable；门面 `@MainActor`，存储/解析协议自由线程。
4. **avatar/NFT 经 `SwiftNft` 接入**：`SwiftDid` 以**可选依赖**接入 `SwiftNft`（对齐 Kotlin `nftSdk: NftSdk? = null`，构造参数 `nft: (any DidNftResolution)?`）；头像解析回退链与 Kotlin 一致：`DidAvatarResolver`（宿主注入）→ `SwiftNft` → 本地兜底解析；未注入时相关方法返回 nil，协议缝保证宿主无 SwiftNft 也能编译。
5. **对接 SwiftDappConnect**：实现 `DidSDK` 协议（`didGenerateBase58PublicKey` / `signCredential` / `ipfsPersonalSign` / `ipfsGetPublicKey`），成为中间件 `did_*` / `ipfs_*` 方法的真实后端。

## 快速开始

```swift
import SwiftDid
import SwiftNft
import GRDB

// 存储：GRDB（对应 Kotlin Room）
let db = try DatabasePool(path: ".../did.sqlite")
let did = try SwiftDid(store: GRDBDidStore(database: db))  // 不接 SwiftNft：头像相关方法返回 nil

// 头像解析后端（可选）：SwiftNft（EVM tokenURI 由模块默认解析器提供、SWTC 由宿主注入，RPC 均不内置）
let nft = try SwiftNft(config: SwiftNftConfig(
    store: GRDBNftStore(database: DatabasePool(path: ".../nft.sqlite")),
    ethTokenUriResolver: EthTokenUriResolver(getRpcNode: { chainId in
        chainId == 1 ? "https://ethereum-rpc.publicnode.com" : nil
    }),
    swtcTokenUriResolver: SwtcTokenUriResolver(getRpcNode: { "https://srje115qd43qw2.swtc.top" })
))
let did = try SwiftDid(store: GRDBDidStore(database: db), nft: nft)

try did.start()

// 链上解析（三态：.document / .missing / .error，不 throw）
switch await did.resolveDid("did:ethr:0x...") {
case .document: break
case .missing: print("链上不存在")
case let .error(error): print("解析失败：\(error.localizedDescription)")
}

// 头像：Profile VC（读 preferredAvatar）→ SwiftNft 元数据/图片
if let profile = await did.generateProfileVC("did:ethr:0x...") {
    print(profile.nft?.image ?? "无头像")
}

// DApp 签名面（SwiftDappConnect.DidSDK）
let signature = try await did.ipfsPersonalSign(privateKey: "0x...", data: [1, 2, 3])
```

## 模块结构

```text
Sources/SwiftDid/
├── SwiftDid.swift                  // 门面（@MainActor，实现 DidSDK）：解析/观察/展示/写操作/验证 + NFT 透传
├── Model/
│   ├── DidModels.swift             // Did / Profile / Nft / ProfileVC / DidEntity / DidResolveOutcome /
│   │                               //   DidPending / QueryVcidResult 等
│   └── CredentialModels.swift      // 凭证/VC 模型（NFT 元数据 DTO 已迁入 SwiftNft，经 import SwiftNft 用非限定名）
├── Service/
│   ├── DidCoreService.swift        // 观察/取档/写操作编排 + pending 对账状态机（不 throw，三态）
│   ├── DidStore.swift              // 存储协议（含 pending CRUD）
│   ├── GRDBDidStore.swift          // GRDB 实现：did_documents / did_pending 表
│   ├── DidResolver.swift           // 链上解析协议（桥方法透传）
│   └── DidDocumentEditor.swift     // DID 文档编辑（增删凭证/改 Profile）
├── Bridge/
│   └── DidBridge.swift             // 桥协议（类型化 did-bridge 方法面）+ WebviewBridgeEngine
│                                   //   （WebviewBridgeClient 实现，默认 bundle，网关硬编码）
└── Util/
    ├── Keccak256.swift             // keccak-256 自实现（EIP-55 checksum 用）
    ├── ChecksumUtils.swift         // EIP-55 地址校验和
    ├── DidJson.swift               // DID 文档字段读取（readProfileField/extractUpdated；
    │                               //   通用 JSON 取值/解析归口 SwiftCore.Json，时间戳归口 SwiftCore.Date）
    └── DidCredentialHelper.swift   // 凭证/头像 VC 辅助
```

## 主要 API

| 类别 | API |
| --- | --- |
| 生命周期 | `start()` / `destroy()` |
| 观察 | `observeDidDocument(_:)` / `observeAllDidDocuments()`（AsyncStream） |
| 解析/读取 | `resolveDid(_:)`（三态，不 throw）/ `getDidDocument(_:)` / `generateDid(_:)` |
| 展示模型 | `generateProfileVC(_:)`（preferredAvatar VC + 预取 nft_meta）/ `generateSwtcNft(_:)` / `generateEthrNft(_:)` / `getAvatarNftCredentials(account:)` / `nickname(_:)` / `getProfile(_:)` |
| 写操作 | `uploadInitialDidDoc` / `updateDidNickname` / `updateDidAvatar` / `publishDidDelete` / `addCredentialToDid` / `deleteCredentialFromDid` / `bindVcidToDid` / `updatePreferredAvatar`（pending 对账） |
| 验证 | `verifyCredential(_:)` / `queryAndValidateVcid(_:)` / `checkGranteeCredentialUpdate(_:)` |
| DApp 签名面（DidSDK） | `didGenerateBase58PublicKey` / `signCredential` / `ipfsPersonalSign` / `ipfsGetPublicKey` |
| NFT 透传（SwiftNft 接入） | `resolveCredentialImage`（重载）/ `resolveCredentialImages` / `fetchResolvedMetadataImage` / `normalizeAssetUrl` / `extractResolvedMetadataImageUrl` / `isSupportedRemoteAssetUrl` / `extractSwtcMetadataUri` / `fetchMetadataFields` / `ensureSwtcCredentialMetadata` |
| 宿主注入点 | `DidAvatarResolver` / `DidAvatarCredentialSource`（回退链第 1 级，优先于 SwiftNft） |

## Notes

- **自持 DID 隐藏 WebView**：`WebviewBridgeEngine.shared` 一个 client 只能承载一个 bridge 页面（已被 SwiftWallet 占用），SwiftDid 自持 `WebviewBridgeClient` 加载 `did-bridge.html`，与 Kotlin 的独立 WebView 对齐。
- **pending 对账状态机（Swift 增强）**：四张 Kotlin 内存表合并为 `did_pending` 单表（kind 列）持久化到 GRDB，消除 Kotlin 内存态的重启丢失窗口；TTL 24h（`deleteExpiredPending` 启动时清理，不启动定时器）；create/delete/avatar/nickname 对账逻辑对齐 Kotlin，含**删除防复活**守卫（`pendingDelete` 检查前置到本地 upsert 之前）。
- **解析三态不 throw**：`resolveDid` 返回 `.document / .missing / .error`，桥/网络错误不伪装成「链上缺失」（对齐 Kotlin 修正 #2）。
- **IPFS 网关硬编码（D5 接受）**：复用现有 `did-bridge.js`，其硬编码网关 `https://wodecards.wh.jccdex.cn:8550` **保持原样、不做注入**（与 Kotlin `:did` 现状一致，见 security-review.md D5）。
- **安全**：`signCredential` 只做结构校验（对齐 Kotlin M-15 三条），用户确认由宿主 UI 完成；私钥经 JS 桥传输的内存边界同 `SwiftWallet`；日志不打 payload。
- **并发**：门面 `@MainActor`；`DidStore` / `DidResolver` / `DidNftResolution` 等 I/O 协议自由线程。

## Design Docs

完整设计稿（Kotlin 架构解析、Swift 设计、did-bridge 协议与 JS、迁移与测试策略）：

[Docs/Did-Swift/README.md](../../Docs/Did-Swift/README.md)
