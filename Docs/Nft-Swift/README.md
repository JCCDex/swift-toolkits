# NFT · Swift 移植设计稿

本文档是 `kotlin-toolkits` 中 `:nft` 模块的 Swift 版本设计。目标是把 Kotlin 版「NFT 元数据解析与缓存、本地 NFT 持仓存储、DID 头像/凭证图片解析」能力以 Swift/iOS 惯用方式复刻为 **`SwiftNft`** 模块，并作为 `SwiftDid` 的 `DidNftResolution` 接入点实现（对齐 Kotlin `DidSdk(nftSdk: NftSdk? = null)` 的可选接入语义）。

> 状态：**已实现落库**（`Sources/SwiftNft/`，commit `1c42534` 起；对齐 `kotlin-toolkits` 源码 commit `f77b59f`，2026-08-18）。设计稿按 Kotlin 源码逐项对齐，实现级补充与偏离见 04 §5（实现回写表）。Kotlin 源码路径：`nft/src/main/java/com/jccdex/toolkits/nft/`（`NftSdk.kt` / `model/NftModels.kt` / `remote/*` / `storage/room/*`）。
>
> 对齐结论速览：`NftSdk` 14 个公开方法签名、`Nft`/`AvatarCandidate`/`NftMetadataFields`/`CredentialImageRequest`/`ResolvedCredentialImage`/`IEthTokenUriResolver` 字段、Room 四表（`nft_meta`/`swtc_nfts`/`evm_nft_items`/`evm_nft_collections`）、`SsrfGuard` 语义、`normalizeRemoteAssetUrl` 规则、SWTC `erc_info` RPC 协议均已逐一对齐（详见 01/03 章）。

## 设计原则

1. **镜像 Kotlin `NftSdk` 全量方法面与模型**：`NftSdk` 共 **14 个公开方法**（13 个方法名，`resolveCredentialImage` 两个重载），Swift `SwiftNft` 逐一镜像；`fetchMetadataFields` 返回**非 Optional**（对齐 `NftSdk`，失败返回 `NftMetadataFields(null,null,null)` 而非抛错）；`fetchAndCacheNftMeta` 返回 `NftMeta?`（对齐 Kotlin 返回 Room 实体 `NftMetaEntity?`）。
2. **存储用 GRDB 替代 Room**：Kotlin `:nft` 自带本地 NFT 存储（`NftRoomDatabase`，四表，见 01 §6）；Swift 侧用 [GRDB.swift](https://github.com/groue/GRDB.swift) 复刻（`NftStore` 协议 + `GRDBNftStore`），宿主把钱包持仓同步进来（`upsertSwtcNfts` / `upsertEvmNftItems`），`getAvatarCandidates` 从本地表读候选（对齐 Kotlin）。
3. **纯原生网络层，不造桥**：Kotlin 用 `HttpURLConnection` 直连（非 OkHttp/Retrofit），Swift 侧用 `URLSession` + 可注入 `NftHttpClient` 协议，**不依赖 JS 桥 / 隐藏 WebView**。网络行为逐项对齐：元数据拉取**不跟随重定向**（`instanceFollowRedirects = false`）、10s 超时、`SsrfGuard` 校验（DNS 解析 fail-closed、拒绝回环/私网/链路本地地址）。
4. **Swift 化 API**：`suspend` → `async throws`（非 Optional 签名除外），Gson/org.json → Codable DTO，模型 `Sendable`，解析层自由线程（不加 `@MainActor`，对齐 `DidNftResolution` 协议缝）。
5. **安全边界**：`SsrfGuard` 语义与 Kotlin 一致（http/https/data + DNS 解析校验，公网 IP 放行、私网/回环/未解析拒绝）；模块不面向 DApp 任意地址查询（`eth_requestNfts` 等属 SwiftDappConnect `NftProvider` 的宿主职责，见 M3），只服务 DID/头像等**内部路径**与本地持仓。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-kotlin-architecture.md](01-kotlin-architecture.md) | Kotlin 版模块解析（已对齐源码）：`NftSdk` 全量 14 方法、模型、解析链路、Room 四表、`SsrfGuard`/网络行为、测试基线 |
| [02-swift-design.md](02-swift-design.md) | Swift 版设计：`SwiftNft` 模块布局、**DTO 归属与依赖方向迁移**、GRDB 存储、模型与代码草案、缓存、并发与安全要点 |
| [03-protocol-and-js.md](03-protocol-and-js.md) | 元数据协议：ERC-721 元数据 JSON、SWTC `erc_info` RPC（hex InfoType/InfoData）、IPFS 网关重写、`normalizeRemoteAssetUrl` 规则、`SsrfGuard` 安全 |
| [04-migration-and-testing.md](04-migration-and-testing.md) | Kotlin → Swift 逐项对照、实现坑（Room→GRDB / SSRF-DNS / data: 支持 / 缓存语义）、测试策略与实施清单 |

## 快速接入

```swift
import SwiftNft

// 存储：GRDB（对应 Kotlin Room nft_storage.db）；网关/RPC 节点可注入（默认对齐 Kotlin 硬编码值）
let store = try GRDBNftStore(database: DatabasePool(path: ".../nft.sqlite"))
let nft = SwiftNft(config: SwiftNftConfig(
    store: store,
    ipfsGateway: URL(string: "https://ipfs.jccdex.cn/ipfs/"),   // 默认对齐 Kotlin DEFAULT_IPFS_GATEWAY_BASE_URL
    ethTokenUriResolver: EthTokenUriResolver(   // 模块默认 eth_call 实现（RPC URL 由函数注入，不内置）；
        rpcUrlsForChain: { chainId in           // 宿主按 chainId 返回该链 RPC URL，nil = 无节点
            chainId == 1 ? "https://ethereum-rpc.publicnode.com" : nil
        },
    ),
    getRpcNode: { "https://srje115qd43qw2.swtc.top" }           // SWTC erc_info 节点（宿主注入，不内置）
))

// 宿主把钱包持仓同步进本地存储（对齐 Kotlin NftStore.upsert*）
try await store.upsertSwtcNfts(entities)
try await store.upsertEvmNftItems(entities)

// 直接能力（fetchMetadataFields 非 Optional、不 throw，对齐 Kotlin NftSdk）
let fields: NftMetadataFields = await nft.fetchMetadataFields(metadataUri)
let imageURL = await nft.resolveCredentialImage(nil, metadataUri: metadataUri)
let meta: NftMeta? = await nft.fetchAndCacheNftMeta(contract: "issuer", tokenId: "1", tokenUri: tokenUri)  // generateProfileVC 前置
```

## 与 Kotlin 差异一览

| 维度 | Kotlin | Swift |
| --- | --- | --- |
| 网络 | `HttpURLConnection`（元数据拉取不跟随重定向） | `URLSession` + `NftHttpClient` 协议（可注入 Fake/URLProtocol；同样不跟随重定向） |
| 入口 | `NftSdk.create(context, databaseName = "nft_storage.db", ethTokenUriResolver)` | `SwiftNft(config:)`（无需 Context；store/网关/RPC 节点/解析器经 config 注入） |
| EVM tokenURI | eth_call 解析器在 **app 侧**（`com.android.jdid.repository`），`:nft` 仅注入接口 | SwiftNft **随包提供默认实现** `EthTokenUriResolver`（`init(rpcUrlsForChain:)` 注入「chainId → RPC URL」函数、模块不内置），宿主可注入自实现（见 02 §4.2） |
| 存储 | Room（`NftRoomDatabase`，`nft_storage.db`） | **GRDB**（`GRDBNftStore`，四表同构） |
| 并发 | `suspend` + `Dispatchers.IO` | `async throws`（自由线程，非 @MainActor） |
| 反序列化 | Gson / org.json | `JSONDecoder` + Codable DTO |
| 图片解析缓存 | `NftMetadataImageCache`（进程内 ConcurrentHashMap，**只缓存成功结果**） | `NftMetadataImageCache`（actor，同语义：瞬时失败不缓存、可重试） |
| IPFS 网关 | **硬编码默认** `https://ipfs.jccdex.cn/ipfs/` | 默认同值但**可注入**（宿主可换网关；见 03 §4） |
| DID 接入 | `:did` 编译期依赖 `:nft`，`DidSdk.create` 内 `NftSdk.create(...)` | 阶段一：DTO/协议缝在 SwiftDid；阶段二：DTO 与 `DidNftResolution` 协议缝迁入 SwiftNft，SwiftDid 依赖 SwiftNft，构造时 `nft: (any DidNftResolution)? = nil`（见 02 §2） |
| 模块边界 | `:nft` 管元数据 + 本地持仓存储；DApp 持仓枚举是 App 自实现 | 同 Kotlin：`eth_requestNfts`/`swtc_requestNfts` 走宿主 `NftProvider`（SwiftDappConnect），宿主可用 SwiftNft 的存储支撑 |

## 关键设计点

- **DTO 归属与依赖方向（对 Did 设计稿的显式修正）**：Kotlin 中 `AvatarCandidate`/`NftMetadataFields` 等定义在 `:nft`，`DidAvatarAsset` 定义在 `:did` port、`Nft` 在 `:did`/`:nft` 各有一份（字段完全一致，`toDidNft()`/`toDidAvatarAsset()` 是逐字段拷贝）。Did 设计稿为「协议缝编译期可用」把 NFT DTO 前置定义在 SwiftDid——若照「SwiftNft 复用 SwiftDid DTO」实现，依赖方向会变成 `SwiftNft → SwiftDid`（拖入桥 + GRDB）且与 Kotlin 反向。**修正**：阶段一保持 DTO 在 SwiftDid（缝可用）；阶段二 `Nft`/`NftMetadataFields`/`CredentialImageRequest`/`ResolvedCredentialImage`/`AvatarCandidate`/`DidAvatarAsset`/`IEthTokenUriResolver`/`NftMeta` **全部迁入 SwiftNft**（Swift 将 Kotlin 双份 `Nft` 与双份候选模型合并为单类型，显式偏离见 02 §2），**`DidNftResolution` 协议缝一并迁入 SwiftNft**（否则 SwiftNft conform 它会形成 `SwiftDid → SwiftNft → SwiftDid` 依赖环，见 02 §2），SwiftDid 以 `public typealias` 保持公开 API 拼写不变，依赖方向 `SwiftDid → SwiftNft`（对齐 Kotlin `:did → :nft`）。
- **头像解析回退链对齐 Kotlin**：`avatarResolver`（宿主注入）→ `nftSdk.resolveSwtcAvatar`/`resolveEthrAvatar` → 本地兜底 `buildSwtcNft`/`buildEthrNft`（见 [Did-Swift 02 §6](../Did-Swift/02-swift-design.md) 与 01 §4）。
- **`fetchMetadataFields` 非 Optional（NftSdk 层）**：对齐 Kotlin `NftSdk.fetchMetadataFields` 签名，失败返回 `NftMetadataFields(null,null,null)`，不 throw；注意 Kotlin `DidSdk` 的包装方法返回 **`NftMetadataFields?`**（可空），Swift 协议缝沿用非 Optional，属对 `DidSdk` 包装层的显式偏离（见 04 坑 #5）。
- **缓存语义**：`NftMetadataImageCache` 按「规范化后的 metadataUrl」做进程内记忆化，**只缓存成功结果**——瞬时失败（如 HTTP 500）不缓存、下次调用可重试（Kotlin 测试 `resolveCredentialImage retries metadata fetch after a transient failure` 锁定该行为）；`fetchAndCacheNftMeta` 持久化到 `nft_meta` 表（含 `fullContent`）。
- **安全注意**：所有**拉取** URL 过 `SsrfGuard`（http/https + DNS 解析，回环/私网/链路本地/未解析拒绝，公网 IP 放行；`data:` 不经网络、直出仅限 `data:image/*`）；**Swift 修正 Kotlin 的 DNS rebinding（check-then-connect）缺口**——解析全部地址、任一私网即拒，建连策略三选一（HTTPS 不能简单 pin IP + Host 头）：`NWConnection` 连 IP + TLS server-name / 建连后复验 / 接受残余风险；元数据拉取不跟随重定向，**RPC 重定向目标再查 `SsrfGuard`**；不记录元数据 payload（可能含隐私）。

## 模块边界（与其他 Swift 模块的分工）

| 能力 | 归属模块 | 说明 |
| --- | --- | --- |
| NFT 元数据解析/缓存、头像/凭证图片解析、**本地持仓存储**（四表 + 同步 API） | **SwiftNft**（本设计稿） | 镜像 Kotlin `:nft` 的 `NftSdk` + `NftStore` |
| `eth_requestNfts` / `swtc_requestNfts`（DApp 面持仓枚举） | SwiftDappConnect `NftProvider`（宿主实现） | 模型 `EvmNftResult` / `SwtcNftResult` 已在 SwiftDappConnect；`nftProvider` 未配置返回空结构 `{address, total:0, nfts:[]}`；宿主可用 SwiftNft 的存储/客户端支撑实现 |
| SWTC NFT 转账（`sendNftTransactionWithPassword`） | SwiftWallet + SwiftDappConnect `SwtcMiddleware` | `buildSwtcNftTransfer`（`serialize721Payment`）已实现；原生路径用 `WebOrigin.walletInternal` 哨兵（M-18） |
| NFT 元数据 DTO | **SwiftNft**（`Model/NftModels.swift`，含 `IEthTokenUriResolver` 协议） | 阶段二已从 SwiftDid 迁入（含 `DidNftResolution` 协议缝，防依赖环，见 02 §2）；SwiftDid 以 `public typealias` 保持公开拼写 |
