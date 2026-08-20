# SwiftNft

`kotlin-toolkits` 中 `:nft` 模块的 Swift 移植：NFT 元数据解析与缓存、本地 NFT 持仓存储（GRDB 四表）、DID 头像/凭证图片解析。随包提供 EVM `tokenURI(uint256)` eth_call 默认解析器（`EthTokenUriResolver`，RPC 端点由宿主注入）与 SWTC `erc_info` 元数据 URI 解析器（`SwtcTokenUriResolver`）。

## 设计原则

1. **镜像 Kotlin `NftSdk` 全量方法面**：`SwiftNft` 门面 14 个公开方法（13 个方法名 + `resolveCredentialImage` 重载）逐一镜像；`fetchMetadataFields` 返回**非 Optional**（失败返回 `NftMetadataFields(null,null,null)` 不抛错，对齐 `NftSdk`）；`fetchAndCacheNftMeta` 返回 `NftMeta?`（对齐 Kotlin 的 Room 实体返回）。
2. **GRDB 替代 Room**：`NftStore` 协议 + `GRDBNftStore` 实现，四表同构（`nft_meta` / `swtc_nfts` / `evm_nft_items` / `evm_nft_collections`），宿主把钱包持仓同步进来（`upsertSwtcNfts` / `upsertEvmNftItems`），`getAvatarCandidates` 从本地表读候选。
3. **纯原生网络，无 JS 桥**：`URLSession` + 可注入 `NftHttpClient` 协议（可注入 Fake/URLProtocol）；元数据拉取**不跟随重定向**、10s 超时、2 MiB body 上限、`SsrfGuard` 校验（DNS 解析 fail-closed、拒绝回环/私网/链路本地）。
4. **Swift 化 API**：`suspend` → `async throws`（非 Optional 签名除外），模型 `Codable + Sendable`，解析层自由线程（不加 `@MainActor`，对齐 `DidNftResolution` 协议缝）。

## 快速开始

```swift
import SwiftNft
import GRDB

// 存储：GRDB（对应 Kotlin Room nft_storage.db）
let store = try GRDBNftStore(database: DatabasePool(path: ".../nft.sqlite"))

let nft = SwiftNft(config: SwiftNftConfig(
    store: store,
    // EVM tokenURI：模块默认 eth_call 实现；RPC URL 由宿主按 chainId 注入（模块不内置任何端点）
    ethTokenUriResolver: EthTokenUriResolver(getRpcNode: { chainId in
        switch chainId {
        case 1: "https://ethereum-rpc.publicnode.com"
        case 137: "https://polygon-rpc.com"
        default: nil
        }
    }),
    // SWTC erc_info：节点由宿主注入（SwtcTokenUriResolver 与 EthTokenUriResolver 均走 NftHttpClient.fetchRpc）
    swtcTokenUriResolver: SwtcTokenUriResolver(getRpcNode: { "https://srje115qd43qw2.swtc.top" })
    // 可选项：ipfsGateway（默认 https://ipfs.jccdex.cn/ipfs/，可换）、
    // httpClient（默认 URLSessionNftHttpClient，含 fetchRpc：POST JSON-RPC + 跟随重定向）
))

// 直接能力
let fields: NftMetadataFields = await nft.fetchMetadataFields(metadataUri)          // 非 Optional、不 throw
let meta: NftMeta? = await nft.fetchAndCacheNftMeta(contract: "issuer", tokenId: "1", tokenUri: tokenUri)
let imageURL: String? = await nft.resolveCredentialImage(nil, metadataUri: metadataUri)

// 宿主把钱包持仓同步进本地存储（对齐 Kotlin NftStore.upsert*）
try await store.upsertSwtcNfts(entities)
try await store.upsertEvmNftItems(entities)
```

## 模块结构

```text
Sources/SwiftNft/
├── SwiftNft.swift                  // 门面：14 方法镜像 NftSdk（薄封装）+ DidNftResolution 协议缝
├── SwiftNftConfig.swift            // store / ipfsGateway / httpClient / ethTokenUriResolver / swtcTokenUriResolver
├── Model/NftModels.swift           // Nft / DidAvatarAsset / NftMetadataFields / CredentialImageRequest /
│                                   //   ResolvedCredentialImage / IEthTokenUriResolver / NftMeta / 持仓实体
├── Store/NftStore.swift            // 协议：持仓 CRUD/观察（纯存储）
├── Store/GRDBNftStore.swift        // GRDB 实现：nft_meta / swtc_nfts / evm_nft_items / evm_nft_collections 四表
├── Util/NftUrlUtils.swift          // normalizeRemoteAssetUrl / isLoadableRemoteAssetUrl /
│                                   //   extractMetadataImageUrl / extractSwtcMetadataUri
├── Net/NftHttpClient.swift         // 协议 + URLSession 实现（fetchJson/fetchText 不跟随重定向；fetchRpc POST 跟随重定向）
├── Net/SsrfGuard.swift             // SSRF 守卫（DNS 解析 fail-closed；拒回环/私网/链路本地；公网放行）
├── Net/SwtcTokenUriResolver.swift  // SWTC erc_info RPC（getRpcNode 单节点注入，节点可信跟随重定向）
├── Net/EthTokenUriResolver.swift   // EVM tokenURI eth_call 默认实现（RPC URL 由 init 注入，不内置）
└── Cache/NftMetadataImageCache.swift // 图片解析记忆化缓存（actor；只缓存成功结果；per-key in-flight 去重）
```

## 主要 API

| 类别 | API |
| --- | --- |
| 头像解析 | `resolveSwtcAvatar(vc:)` / `resolveEthrAvatar(vc:)` / `getAvatarCandidates(account:)` |
| 元数据 | `fetchAndCacheNftMeta(contract:tokenId:tokenUri:)`（落 `nft_meta`）/ `fetchMetadataFields(_:)`（非 Optional）/ `ensureSwtcCredentialMetadata(_:)` |
| 图片解析 | `resolveCredentialImage(_:metadataUri:)` / `resolveCredentialImage(_ request:)` / `resolveCredentialImages(_:)`（按 key 去重 + 有界并发）/ `fetchResolvedMetadataImage(_:)` |
| 纯函数 | `normalizeAssetUrl(_:baseUrl:)` / `extractResolvedMetadataImageUrl(_:metadataUri:)` / `isSupportedRemoteAssetUrl(_:)` / `extractSwtcMetadataUri(_:)` |
| 模型 | `Nft` / `DidAvatarAsset` / `NftMetadataFields` / `CredentialImageRequest` / `ResolvedCredentialImage` / `NftMeta` / `SwtcNftEntity` / `EvmNftItemEntity` / `EvmNftCollectionEntity` |
| 协议 | `DidNftResolution`（SwiftDid 接入缝，宿主可注入自实现）/ `IEthTokenUriResolver`（EVM tokenURI）/ `NftStore` / `NftHttpClient` / `ISwtcTokenUriResolver` |
| 默认实现 | `EthTokenUriResolver`（eth_call，`init(getRpcNode:)` + `httpClient`）/ `SwtcTokenUriResolver`（erc_info，`init(getRpcNode:)` + `httpClient`）——两者均走 `NftHttpClient.fetchRpc`（POST JSON-RPC、跟随重定向） |

## Notes

- **EVM tokenURI**：`IEthTokenUriResolver` 是非 throw 注入接口（失败返回 nil）；模块随包提供默认实现 `EthTokenUriResolver`（ERC-721 `tokenURI(uint256)`，selector `0xc87b56dd`，calldata 只拼 32 字节十进制 tokenId、合约地址走 `to` 字段，ABI string 解码假定 offset=32，URI 过 `normalizeRemoteAssetUrl`）——**RPC 端点不内置**，由 `getRpcNode` 闭包按 chainId 提供单个 URL。
- **缓存语义（成功才缓存）**：`NftMetadataImageCache` 只缓存**成功**结果（HTTP 500 等瞬时失败不缓存、可重试）；并发同 key 只 fetch 一次（per-key Task in-flight 去重）；`nft_meta`/图片缓存无 TTL（对齐 Kotlin）。
- **安全边界**：所有拉取 URL 过 `SsrfGuard`（http/https + DNS 解析，回环/私网/链路本地/未解析拒绝，公网放行）；元数据拉取不跟随重定向；**SWTC RPC 例外：节点可信、跟随重定向**（无 delegate，对齐 Kotlin）；`data:` 直出仅限 `data:image/*`（宿主渲染第三方图片用 `UIImage`/`CGImage`，勿用 WKWebView）；日志不落元数据 payload。
- **注入信任面**：`swtcTokenUriResolver` / `ethTokenUriResolver` / `ipfsGateway` 均属宿主配置（模块**不内置任何节点/端点**）；`SwtcTokenUriResolver` 经 `getRpcNode` 注入节点（自建普通 session，跟随重定向）。
- **并发**：门面自由线程（非 @MainActor），`NftStore: Sendable`（GRDB DatabasePool 线程安全）。

## Design Docs

完整设计稿（Kotlin 架构解析、Swift 设计、元数据协议与 JS 分工、迁移与测试策略）：

[Docs/Nft-Swift/README.md](../../Docs/Nft-Swift/README.md)
