# 02 · Swift 版设计

> 对齐依据：`kotlin-toolkits` commit `f77b59f`（`nft/src/main/java/com/jccdex/toolkits/nft/`）。本节 Swift 代码为设计草案，签名与行为对齐 Kotlin 源码。

## 1. 模块布局

```text
Sources/SwiftNft/
├── SwiftNft.swift               // 门面：14 方法镜像 NftSdk（薄封装 NftStore）
├── SwiftNftConfig.swift         // store / ipfsGateway / httpClient / ethTokenUriResolver / rpcNodes / pins
├── Model/NftModels.swift        // Nft / AvatarCandidate / NftMetadataFields / CredentialImageRequest /
│                                //   ResolvedCredentialImage / EthTokenUriResolver / DidAvatarAsset / NftMeta
├── Store/NftStore.swift         // 协议：持仓 CRUD/观察（纯存储；解析/编排逻辑归属 SwiftNft 门面，见 §5）
├── Store/GRDBNftStore.swift     // GRDB 实现：nft_meta / swtc_nfts / evm_nft_items / evm_nft_collections 四表
├── Util/NftUrlUtils.swift       // normalizeRemoteAssetUrl(raw, base, gateway:) / isLoadableRemoteAssetUrl /
│                                //   extractMetadataImageUrl / extractSwtcMetadataUri / looksLikeImageAssetUrl
├── Net/NftHttpClient.swift      // 协议 + URLSession 实现（fetchJson/fetchText；不跟随重定向）
├── Net/SsrfGuard.swift          // SSRF 守卫（DNS 解析 fail-closed；拒回环/私网/链路本地；公网 IP 放行）
├── Net/SwtcChainNftClient.swift // SWTC erc_info RPC（rpcNodes + 可选证书 pinning）
└── Cache/NftMetadataImageCache.swift // 图片解析记忆化缓存（只缓存成功结果）
```

> 本模块**无 JS 资产、无 WebView**：纯原生网络 + GRDB + 解析层（与 SwiftDid/SwiftWallet 的桥式架构区分，见 README「模块边界」）。

`Package.swift` 目标（阶段二）：

```swift
.target(
    name: "SwiftNft",
    dependencies: [
        // 仅取 WalletAccount / ChainType 模型（SwiftDappConnect 零运行时依赖，很轻；对应 Kotlin :core）；
        // 不依赖 SwiftWebviewBridge —— 这是把 DTO 迁入本模块的动因（见 §2）。
        .target(name: "SwiftDappConnect"),
        .product(name: "GRDB", package: "GRDB")   // 对应 Kotlin Room
    ],
    path: "Sources/SwiftNft"
)
```

## 2. DTO 归属与依赖方向（对 Did 设计稿的显式修正）

**Kotlin 实况**：`AvatarCandidate`/`NftMetadataFields`/`CredentialImageRequest`/`ResolvedCredentialImage`/`EthTokenUriResolver` 在 `:nft`；`DidAvatarAsset` 在 `:did` port；`Nft` 在 `:did` 与 `:nft` **各有一份**（字段完全一致，`toDidNft()`/`toDidAvatarAsset()` 是逐字段拷贝——Kotlin 因模块边界重复定义，属既有冗余）。

**问题**：Did 设计稿为「协议缝编译期可用」把 NFT DTO 前置定义在 SwiftDid，并写「SwiftNft 复用」——照做则依赖方向为 `SwiftNft → SwiftDid`，会把桥 + GRDB 拖进纯元数据模块，且与 Kotlin `:did → :nft` 反向。

**修正方案（两阶段）**：

| 阶段 | 状态 | DTO 归属 | 依赖方向 |
| --- | --- | --- | --- |
| 一 | SwiftNft 未落库（现状） | NFT DTO 定义在 SwiftDid（`Model/NftModels.swift`） | SwiftDid 无 SwiftNft 依赖，协议缝编译期可用 |
| 二 | SwiftNft 落库 | 下列类型**全部迁入 SwiftNft**；SwiftDid 保留 `public typealias`，公开 API 拼写不变 | SwiftDid 增加 `.target(name: "SwiftNft")` 依赖（对齐 Kotlin `:did → :nft`） |

```swift
// 阶段二 · SwiftDid 侧（保持公开 API 源兼容，消费者无需改代码）：
public typealias Nft = SwiftNft.Nft
public typealias NftMetadataFields = SwiftNft.NftMetadataFields
public typealias CredentialImageRequest = SwiftNft.CredentialImageRequest
public typealias ResolvedCredentialImage = SwiftNft.ResolvedCredentialImage
public typealias DidAvatarAsset = SwiftNft.DidAvatarAsset   // AvatarCandidate 已合并入此类型（见下）
public typealias NftMeta = SwiftNft.NftMeta                 // fetchAndCacheNftMeta 的返回类型，缝签名引用
public typealias EthTokenUriResolver = SwiftNft.EthTokenUriResolver
public typealias DidNftResolution = SwiftNft.DidNftResolution   // 协议缝随 DTO 一并迁入（见下）
```

> typealias 清单 = **阶段二 SwiftDid 仍公开引用的全部 NFT 拼写**（含协议缝签名用到的 `NftMeta` /
> `DidAvatarAsset`——缺了它们 `fetchAndCacheNftMeta` 的返回类型与 `getAvatarCandidates` 的返回类型
> 在 SwiftDid 侧就对不上）。`AvatarCandidate` 在 SwiftNft 内仅保留 `typealias AvatarCandidate =
> DidAvatarAsset`（Kotlin 命名保真，非独立类型）。
> **协议缝必须随 DTO 迁移（依赖无环的前提）**：`DidNftResolution` 现定义在 SwiftDid；若阶段二
> 只迁 DTO 不迁协议，SwiftNft 要 conform 它就得 `import SwiftDid`，形成 `SwiftDid → SwiftNft →
> SwiftDid` 的环。阶段二**把协议缝本身也迁入 SwiftNft**（14 个方法签名不动），SwiftDid 用上面的
> `typealias` 保持公开拼写；依赖图才成立。

**对 Kotlin 的显式合并偏离（字段完全一致才合并，落地前用字段对照表校验）**：

1. **双 `Nft` 合并**：Kotlin `:did.Nft` 与 `:nft.Nft` 8 字段逐字段一致（`toDidNft()` 为直拷贝），Swift 只保留 `SwiftNft.Nft` 一个类型，`SwiftDid` 不再重复定义展示模型（`ProfileVC` 等经 typealias 引用）。
2. **`AvatarCandidate` 与 `DidAvatarAsset` 合并**：两类型 8 字段一致（`toDidAvatarAsset()` 为直拷贝），Swift 保留 `SwiftNft.DidAvatarAsset` 一个类型（命名取 `DidAvatarAsset`，因其同时服务 `DidNftResolution` 协议缝签名）；SwiftNft 的 `getAvatarCandidates` 返回 `[DidAvatarAsset]`（Kotlin 返回 `[AvatarCandidate]`，等价）。
3. **`fetchMetadataFields` 可空性**：Kotlin `NftSdk` 返回非 Optional，`DidSdk` 包装方法返回 Optional；Swift 协议缝沿用**非 Optional**（对齐 NftSdk），属对 DidSdk 包装层的显式偏离（见 04 坑 #5）。

> 依赖图（阶段二）：`SwiftDid → SwiftNft → SwiftDappConnect`（模型）+ GRDB；`SwiftDid → SwiftDappConnect`。无环（前提：`DidNftResolution` 协议缝随 DTO 迁入 SwiftNft，见上）。宿主构造 `SwiftDid(..., nft: SwiftNft(...))` 即可接入。

## 3. 模型（镜像 Kotlin，Codable + Sendable）

```swift
// 展示模型（8 字段，字段名 `contract` 而非 `contractAddress`）
public struct Nft: Codable, Sendable, Equatable {
    public let contract: String
    public let tokenId: String
    public let name: String
    public let uri: String
    public let issuanceDate: String
    public let image: String?
    public let hasLocal: Bool
    public let chainId: Int64?
}

// 头像候选（字段与 Kotlin AvatarCandidate / DidAvatarAsset 一致，见 §2 合并决策）
public struct DidAvatarAsset: Codable, Sendable, Equatable {
    public let image: String?
    public let name: String
    public let contract: String?
    public let tokenId: String
    public let issuer: String?
    public let tokenName: String?
    public let chainId: Int64?
    public let isSwtc: Bool
}

// 元数据字段（仅 3 字段；fetchMetadataFields 失败返回 .empty，不 throw）
public struct NftMetadataFields: Codable, Sendable, Equatable {
    public var image: String?
    public var name: String?
    public var description: String?
    public static let empty = NftMetadataFields(image: nil, name: nil, description: nil)
}

// 图片解析请求（5 字段）
public struct CredentialImageRequest: Codable, Sendable, Equatable {
    public let imageUrl: String?
    public let metadataUri: String?
    public let chainId: Int64?
    public let contractAddress: String?
    public let tokenId: String?
}

// 解析结果（url 非空；cacheKey 供宿主缓存图片，构造规则见 01 §4.4）
public struct ResolvedCredentialImage: Codable, Sendable, Equatable {
    public let url: String
    public let cacheKey: String
}

// tokenURI 解析（RPC 宿主实现；模块不内置 eth_call）
public protocol EthTokenUriResolver: Sendable {
    func resolveEthrTokenUri(contract: String, tokenId: String, chainId: Int64) async -> String?
}

// nft_meta 持久化实体（对应 Kotlin NftMetaEntity；fetchAndCacheNftMeta 返回它）
public struct NftMeta: Codable, Sendable, Equatable {
    public var id: Int64?          // 自增主键（记录层）
    public let contract: String
    public let tokenId: String
    public let name: String?
    public let image: String?
    public let tokenUri: String?
    public let fullContent: String?
    public var updatedAt: Int64    // 毫秒
}
```

> 其余持仓实体（`SwtcNftEntity` / `EvmNftItemEntity` / `EvmNftCollectionEntity`）字段与 Kotlin `NftEntities.kt` 一一对应，仅在 GRDB 记录层体现（见 §5），不全部暴露为公开 DTO。

## 4. 网络层

```swift
/// 拉取抽象（可注入 Fake；URLProtocol 可整体 stub）。行为对齐 Kotlin：
/// 10s 超时、**不跟随重定向**、2xx 且 body 非空才成功。
/// ⚠️ URLRequest.timeoutInterval 近似**空闲超时**（≈ Kotlin readTimeout，非「整请求」）；
/// timeoutIntervalForResource 才是总时长；Kotlin 的 connectTimeout 在 URLSession 无直接等价——
/// 若需等价 read-timeout，用流式读取 + 空闲超时，或接受总时长语义并写清。
///
/// **实现偏离（相对 Kotlin `fetchJson`）**：`fetchJson` 返回原始 `Data` 且**不做 JSON 解析校验**——
/// 解析收敛到门面一次（Kotlin 在客户端解析 JsonObject，Swift 客户端校验会与门面重复解析；
/// 门面解析失败即按「解析失败」处理，行为等价）。
public protocol NftHttpClient: Sendable {
    func fetchJson(_ url: URL) async throws -> Data?   // GET JSON 元数据原始 body（不解析）
    func fetchText(_ url: URL) async throws -> String? // GET 文本 body
}

public struct URLSessionNftHttpClient: NftHttpClient, Sendable {
    public let session: URLSession
    public let timeout: TimeInterval
    // 必须用 delegate-backed session：URLSession.shared 没有 delegate，挂不上
    // willPerformHTTPRedirection，会静默跟随重定向（重定向是 SSRF 绕过路径）。
    // 默认构造 NoRedirectDelegate 的 session（对齐 Kotlin instanceFollowRedirects = false）。
    // ⚠️ 注入自定义 session 时，调用方必须保证其**不跟随重定向**（delegate 随 session 固定，
    // 无法挂上 NoRedirectDelegate）——否则重定向是 SSRF 绕过路径（勿传 URLSession.shared）。
    public init(session: URLSession? = nil,
                timeout: TimeInterval = 10,
                maxBodyBytes: Int = 2 * 1024 * 1024) {
        self.session = session ?? Self.noRedirectSession
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
    }
    public static let noRedirectSession = URLSession(
        configuration: .default,
        delegate: NoRedirectDelegate(),   // URLSessionTaskDelegate：willPerformHTTPRedirection → completionHandler(nil)
        delegateQueue: nil
    )
    public var maxBodyBytes: Int
    public func fetchJson(_ url: URL) async throws -> Data? { ... }
    public func fetchText(_ url: URL) async throws -> String? { ... }
}

/// SSRF 守卫（对齐 Kotlin SsrfGuard，并修正其 DNS rebinding 缺口）：
/// - scheme ∈ {http, https}（Kotlin 的 ipfs 白名单在 java 下解析失败按畸形拒绝；Swift 直接拒绝非 http(s)）
/// - host 非空；DNS 解析失败 → fail-closed 拒绝（Swift 用 getaddrinfo / Network 框架解析）
/// - 拒绝 loopback / site-local / link-local（127.0.0.0/8、10/8、172.16/12、192.168/16、169.254/16、
///   ::1、fe80::/10、fc00::/7 等），并补 IPv4-mapped IPv6（::ffff:a.b.c.d 映射回 IPv4 再判）、
///   0.0.0.0 / 255.255.255.255、100.64.0.0/10（CGNAT）、198.18.0.0/15（基准测试）、192.0.0.0/24
///   （IETF 协议保留）、224.0.0.0/4（组播）+ 240.0.0.0/4（保留）、IPv6 ff00::/8（组播）；
///   公网 IP 放行（对齐 Kotlin 测试：8.8.8.8 通过）
/// - **Swift 修正（DNS rebinding / TOCTOU）**：Kotlin check 时解析一次、建连再解析一次，攻击者可
///   「校验返回公网、建连返回私网」绕过。Swift 必须 ① 解析**全部**地址（getaddrinfo 全量），任一
///   私网/回环/链路本地即拒；② 建连策略三选一（**HTTPS 不能简单「pin IP + Host 头」**——证书按
///   主机名校验，那样会失败，除非危险地 override server trust）：
///     a) Network.framework `NWConnection` 连已校验 IP + TLS server-name（sec_protocol_options
///        的 server-name），证书仍按原主机名校验（最稳，实现成本高）；
///     b) 按主机名建连（先全量校验），连接建立后用 `NWConnection.currentPath` 复验对端实际 IP；
///     c) 明确接受残余 TOCTOU 风险（App 内 SSRF 面小），作为已知降级写入文档。
///   ⚠️ **URLSession 不暴露对端实际 IP**（无 peer-address API），方案 b 只对 NWConnection 可行；
///   若用 URLSession 拉取，实际只能在 a（NWConnection 承载数据流）与 c（接受残余风险）之间选，
///   并明确写入文档。
/// - 测试旁路开关仅 internal + #if DEBUG（对齐 Kotlin enabled 标志，但勿做 public 可变全局）
internal enum SsrfGuard {
    #if DEBUG
    internal nonisolated(unsafe) static var enabled = true
    #endif
    static func check(_ url: URL) -> Bool { ... }
}

/// SWTC 链上元数据 URI（对齐 SwtcChainNftClient）：
/// POST {"method":"erc_info","params":[{"tokenid": tokenId}]}，rpcNodes 逐个尝试首个成功返回；
/// 15s 超时；RPC 节点可信可跟随重定向；可选证书 pinning（sha256/Base64）。
/// ⚠️ 可注入 + 安全边界：
/// ① Kotlin 硬编码可信节点故不查 SsrfGuard；Swift 把 rpcNodes 做成可注入，建连前对注入节点做
///    SsrfGuard.check（http/https + 公网）；
/// ② **不复用 `NftHttpClient`**（那是 no-redirect）：本客户端自持 redirect-following 且
///    `willPerformHTTPRedirection` 里对新 URL 再查 `SsrfGuard`（失败不跟随）的 delegate session；
/// ③ 抽协议 seam `SwtcMetadataUriFetching` 供注入 Fake（对齐 Kotlin 构造函数注入 swtcChainNftClient），
///    否则测试策略「Fake SwtcChainNftClient」落不了地。
public protocol SwtcMetadataUriFetching: Sendable {
    func fetchMetadataUri(tokenId: String) async -> String?
}
public struct SwtcChainNftClient: SwtcMetadataUriFetching {
    public static let defaultRpcNodes = ["https://srje115qd43qw2.swtc.top"]
    public var rpcNodes: [String]
    public var certificatePins: [String]       // 默认空（不 pin）
    private let session: URLSession            // 自己的 redirect-following + 重定向目标 SsrfGuard 守卫 session
    public func fetchMetadataUri(tokenId: String) async -> String? { ... }
}

/// IPFS 重写 + 资产 URL 规范化（对齐 normalizeRemoteAssetUrl 的 ipfs 分支 + canonicalizeHttpIpfsUrl）。
/// 网关默认 "https://ipfs.jccdex.cn/ipfs/"（对齐 Kotlin DEFAULT_IPFS_GATEWAY_BASE_URL），可注入。
/// ⚠️ 网关须贯穿**所有做 ipfs→网关重写或调用了它们的纯函数**——`normalizeRemoteAssetUrl(raw, base, gateway:)` /
/// `canonicalizeHttpIpfsUrl(raw, gateway:)`、内部调用 normalize 的 `extractMetadataImageUrl(body, uri, gateway:)`、
/// 以及包装它的 `extractMetadataFields(body, uri, gateway:)`（Util/NftUrlUtils.swift；`looksLikeIpfsIdentifier`
/// 仅检测 CID、不含网关）都要带 `gateway` 参数（默认 defaultGateway），由门面把 `config.ipfsGateway` 层层传入；
/// 否则「可注入网关」只对 rewrite 一条路径生效、ipfs:// 重写仍硬编码默认网关。公开 `normalizeAssetUrl` 签名不变（内部用已注入网关）。
public enum IpfsResolver {
    public static let defaultGateway = "https://ipfs.jccdex.cn/ipfs/"
    public static func rewrite(_ raw: String, gateway: String = defaultGateway) -> String? { ... }
}
```

> **Swift 增强（对 Kotlin 的显式偏离）**：Kotlin 把网关与 RPC 节点**硬编码**（`DEFAULT_IPFS_GATEWAY_BASE_URL` / `DEFAULT_RPC_NODES`）；Swift 经 `SwiftNftConfig` 注入，默认值保持与 Kotlin 相同（行为对齐），宿主可换网关/节点（缓解 `security-review.md` D5 类单点问题）。

## 5. 存储（GRDB 替代 Room）

```swift
/// 持仓/元数据存储（对齐 Kotlin NftStore 方法面；自由线程，GRDB 后台调度）。
/// 解析/编排逻辑（resolveSwtcAvatar 等）归属 SwiftNft 门面（显式偏离：Kotlin 在 NftStore 内实现；
/// Swift 让 NftStore 保持纯存储、可替换，宿主自实现存储时无需连带实现解析）。
public protocol NftStore: AnyObject, Sendable {
    // 元数据缓存表 nft_meta
    func getNftMeta(contract: String, tokenId: String) async throws -> NftMeta?
    func upsertNftMeta(_ entity: NftMeta) async throws

    // SWTC 持仓表 swtc_nfts
    func observeSwtcNfts(ownerAddress: String) -> AsyncStream<[SwtcNftEntity]>
    func upsertSwtcNfts(_ entities: [SwtcNftEntity]) async throws
    func getSwtcNftByIssuerAndTokenId(issuer: String, tokenId: String) async throws -> SwtcNftEntity?
    func getSwtcNftByTokenId(ownerAddress: String, tokenId: String) async throws -> SwtcNftEntity?
    func deleteSwtcNftsByOwner(ownerAddress: String) async throws   // 删除前 preserveSwtcEntityAsMeta

    // EVM 持仓表 evm_nft_items
    func observeEvmNftItems(chainId: String, ownerAddress: String, contractAddress: String) -> AsyncStream<[EvmNftItemEntity]>
    func observeAllEvmNftItems(chainId: String, ownerAddress: String) -> AsyncStream<[EvmNftItemEntity]>
    func upsertEvmNftItems(_ entities: [EvmNftItemEntity]) async throws
    func getEvmNftItemByContractAndTokenId(chainId: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity?
    func getEvmNftItem(chainId: String, ownerAddress: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity?
    func deleteEvmNftItemsByCollection(chainId: String, ownerAddress: String, contractAddress: String) async throws

    // EVM 集合表 evm_nft_collections
    func insertCollections(_ collections: [EvmNftCollectionEntity]) async throws
    func getNftCollectionsFlow(chainId: String, ownerAddress: String) -> AsyncStream<[EvmNftCollectionEntity]>
    func deleteByChainAndOwner(chainId: String, ownerAddress: String) async throws
    func updateTokenCount(chainId: String, ownerAddress: String, contractAddress: String, tokenCount: Int) async throws
}

/// GRDB 实现：四表迁移 + ValueObservation → AsyncStream（模式同 GRDBDidStore，见 Did 02 §4）。
/// 表结构与索引对齐 Kotlin NftEntities.kt：nft_meta（(contract,tokenId) UNIQUE）、
/// swtc_nfts（(ownerAddress,tokenId) 复合 PK）、evm_nft_items（四列复合 PK）、
/// evm_nft_collections（三列复合 PK）。
public final class GRDBNftStore: NftStore, @unchecked Sendable {   // DatabasePool 线程安全
    public init(database: DatabasePool) throws { ... }   // DatabaseMigrator 建四表
    // 查询一律 LOWER() 归一化 address/contract（对齐 Kotlin DAO SQL）
}
```

> 存储选型沿用 Did 的结论：观察流 + 写并发并存直接用 `DatabasePool`（WAL）；`AsyncStream` 在数据库队列交付，SwiftUI 消费需跳主线程。宿主也可自实现 `NftStore` 替换（协议注入）。
>
> **`Sendable`（Swift 6 严格并发）**：`NftStore: AnyObject, Sendable`（`GRDBNftStore` 基于线程安全的
> `DatabasePool`，标 `@unchecked Sendable`），否则 `SwiftNft: Sendable` / `SwiftNftConfig: Sendable`
> 持有 `any NftStore` 会编译不过。
>
> **upsert 语义（对 Kotlin 的修正）**：Kotlin `@Insert(REPLACE)` 是删旧插新，`nft_meta` 自增 `id`
> 会变（Kotlin 为此手动 `entity.copy(id = existing.id)`）；GRDB 直接用 `INSERT ... ON CONFLICT(contract,
> tokenId) DO UPDATE SET ...`（`.upsert`），保留 id、避免行替换副作用；其余三表按各自复合主键同样
> 用 ON CONFLICT DO UPDATE。

## 6. SwiftNft（代码草案，14 方法完整镜像）

```swift
import Foundation
import SwiftDappConnect   // WalletAccount / ChainType

public struct SwiftNftConfig: Sendable {
    public var store: any NftStore                     // 对应 Kotlin NftStore（Room）
    public var ipfsGateway: String = IpfsResolver.defaultGateway   // 默认对齐 Kotlin，可注入（贯穿 ipfs→网关重写，见 §4）
    public var httpClient: any NftHttpClient = URLSessionNftHttpClient()
    public var ethTokenUriResolver: (any EthTokenUriResolver)?     // 对应 Kotlin 构造参数
    public var swtcChainNftClient: (any SwtcMetadataUriFetching)? = nil  // 注入时**优先于** rpcNodes/certificatePins（后两者被忽略）；nil → 用 rpcNodes/pins 建默认实现；测试注入 Fake
    public var rpcNodes: [String] = SwtcChainNftClient.defaultRpcNodes
    public var certificatePins: [String] = []
}

/// 门面：自由线程（不加 @MainActor，对齐 DidNftResolution 协议缝）。
public final class SwiftNft: DidNftResolution, Sendable {
    public init(config: SwiftNftConfig) { ... }

    // MARK: - 头像解析与候选（对齐 NftSdk 3.1）

    public func getAvatarCandidates(account: WalletAccount) async -> [DidAvatarAsset] {
        // SWTC：observeSwtcNfts(account.address).firstValue() → tokenName = fundCodeName.ifBlank{fundCode}
        // EVM：evmChainId → "0x..." hex → observeAllEvmNftItems → 映射（对齐 Kotlin NftStore.getAvatarCandidates）
    }

    public func resolveSwtcAvatar(vc: String) async -> Nft? {
        // 读 VC（JSONPath 等价实现）→ 回退链：nft_meta → swtc_nfts 行 → resolveAndCacheSwtcNftMeta → 裸 Nft
        // （对齐 01 §4.2）
    }

    public func resolveEthrAvatar(vc: String) async -> Nft? {
        // VC → ethTokenUriResolver?.resolveEthrTokenUri → nft_meta → evm_nft_items（对齐 01 §4.3）
    }

    // MARK: - 元数据预取与字段（对齐 NftSdk 3.2）

    public func fetchAndCacheNftMeta(contract: String, tokenId: String, tokenUri: String) async -> NftMeta? {
        guard !tokenUri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // 1) normalizeRemoteAssetUrl(tokenUri, nil, config.ipfsGateway)（ipfs:// 等先归一化并贯穿注入网关，对齐 Kotlin L-R3 注释）
        // 2) SsrfGuard.check → httpClient.fetchJson → name(trim)/image(extractMetadataImageUrl)
        // 3) upsertNftMeta（GRDB ON CONFLICT DO UPDATE，保留自增 id；对齐 Kotlin copy(id) 语义）→ getNftMeta 返回
        // 4) 失败区分：URL 空白 → nil；SSRF 拒绝/网络失败/解析失败 → 打日志（scheme/host，不打 body）
        //    （Kotlin catch-all 吞错返回 nil；Swift 保留不 throw，但对失败路径记日志，见 §8）
    }

    public func fetchMetadataFields(_ metadataUri: String) async -> NftMetadataFields {
        // normalize → fetchText → extractMetadataFields(body, uri)（解 "data" 包、image/image_url/imageUrl）
        // 失败 → .empty（非 Optional，不 throw）
    }

    public func ensureSwtcCredentialMetadata(_ vc: String) async {
        // VC $.credentialSubject.tokenId / nftIssuer → resolveAndCacheSwtcNftMeta
        //（nft_meta 已有 image → 返回；否则 tokenUri = 已有 或 (config.swtcChainNftClient ?? 默认实现).fetchMetadataUri(tokenId)）
    }

    // MARK: - 凭证/元数据图片解析（对齐 NftSdk 3.3，4 签名 = 3 方法名 + resolveCredentialImage 重载）

    public func resolveCredentialImage(_ imageUrl: String?, metadataUri: String?) async -> String? {
        // resolveRemoteImageUrl 四步（内联 JSON 提图 → 直出 → metadataUri 是图片 URL → 拉元数据提图（记忆化））
    }

    public func resolveCredentialImage(_ request: CredentialImageRequest) async -> ResolvedCredentialImage? {
        // url + cacheKey（buildCredentialAssetKey 优先级：image: / nft:chain:contract:token / metadata: / image:）
    }

    public func resolveCredentialImages(_ requests: [CredentialImageRequest]) async -> [ResolvedCredentialImage?] {
        // buildCredentialResolutionKey 去重（对齐 Kotlin LinkedHashMap.getOrPut，nil 值也去重）；
        // **有界并发（实现）**：不同 key 分批复用 ≤ maxConcurrency（4）个 Task，同 key 只解析一次、
        // 结果按请求序回填——Kotlin 顺序执行、全量并行会让大批量瞬间打满连接/线程（见 04 坑 #23）。
        let maxConcurrency = 4
        // requestsByKey（key → 首个请求）去重 → 分批 withTaskGroup 解析 → order.map { resultsByKey[$0] ?? nil }
    }

    public func fetchResolvedMetadataImage(_ metadataUrl: String) async -> String? {
        // SsrfGuard → fetchText → extractMetadataImageUrl（经 NftMetadataImageCache 记忆化）
    }

    // MARK: - 纯函数（Util/NftUrlUtils.swift，规则见 03 §5；同步，对齐 Kotlin 非 suspend）

    public func normalizeAssetUrl(_ rawUrl: String?, baseUrl: String? = nil) -> String? { ... }
    public func extractResolvedMetadataImageUrl(_ metadataBody: String, metadataUri: String) -> String? { ... }
    public func isSupportedRemoteAssetUrl(_ url: String?) -> Bool { ... }
    public func extractSwtcMetadataUri(_ tokenInfosPayload: String?) -> String? { ... }
}
```

## 7. 缓存（NftMetadataImageCache）

```swift
/// 图片解析结果记忆化（对齐 Kotlin NftMetadataImageCache）：
/// - key = 规范化后的 metadataUrl（trim）
/// - **只缓存成功（非 null）结果**；瞬时失败不落缓存，下次调用重新拉取（Kotlin 测试锁定）
/// - 并发去重：同 key 同时发起只执行一次 fetch —— 用 per-key 的 `Task` 缓存做 in-flight 去重
///   （`[String: Task<String?, Never>]`）；**不能**只在 actor 方法内 `await fetch()`：actor 会跨
///   网络调用持有自己 → 所有 key 全局串行；裸 actor 也不提供 in-flight 去重。
public actor NftMetadataImageCache {
    private var resolvedByMetadataUrl: [String: String?] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]
    public func getOrFetch(_ metadataUrl: String,
                           fetch: @escaping @Sendable () async -> String?) async -> String? {
        // 1) 命中 resolvedByMetadataUrl → 直接返回
        // 2) inflight[key] 存在 → await 该 Task（同 key 并发共享一次 fetch）
        // 3) 否则建 Task 存 inflight，fetch 成功（非 null）写 resolvedByMetadataUrl，finally 移除 inflight
    }
    public func removeAll() {
        // 必须同时取消并丢弃 inflight 里所有 Task、清空两个字典——
        // 否则切账户后旧请求仍会继续跑并回写 resolvedByMetadataUrl。
        // （实现：inflight.values.forEach { $0.cancel() }；clear 两字典）
    }
}
```

- **持久化缓存（`nft_meta`）**：`fetchAndCacheNftMeta` 写 GRDB 表（含 `fullContent`，对齐 Kotlin），`resolveSwtcAvatar`/`resolveEthrAvatar` 优先读它——持久化语义已由存储层保证，不另做内存缓存。
- **TTL 说明（与 Kotlin 对齐）**：Kotlin 的 `nft_meta`/图片缓存**无 TTL**（`updatedAt` 仅记录时间）；Swift **一期不做 TTL**（对齐 Kotlin，避免行为漂移），宿主需要时可在 `NftStore` 实现里自行裁剪。图片记忆化缓存有 `removeAll()` 供清理。
- **内存缓存上限（实现：简单 LRU）**：`resolvedByMetadataUrl` 与 `inflight` **都要**加条数/LRU 上限（Kotlin 现状无上限；Swift 轻量增强），否则长生命周期按 metadataUrl 累积会无界增长；实现用 `accessOrder` 数组做命中刷新 + 插入淘汰（`touch` + `while count > maxEntries` 逐出最旧），`removeAll()` 必须取消在途 Task 并清空两字典与 `accessOrder`（见上）。
- **并发失败语义（显式偏离，Swift 更优）**：Kotlin 的 per-key Mutex 在**并发失败**（null 不缓存）时第二个调用者会**重新 fetch**（N 个并发 = N 次拉取）；Swift per-key Task 让并发调用者**共享同一个 null**（1 次拉取）——勿为「对齐 Kotlin」复刻重复拉取（见 04 坑 #16）。

## 8. 并发与安全要点

- **线程模型**：门面/网络/解析**自由线程**（非 @MainActor），与 `DidNftResolution` 协议缝一致；`NftStore`/`GRDBNftStore` 后台调度（GRDB DatabasePool）；`NftMetadataImageCache` 用 `actor`。不引入主线程 hop，避免 `resolveCredentialImages` 批量场景的线程切换开销。**`NftStore` 协议标 `Sendable`**（`GRDBNftStore` `@unchecked Sendable`），否则 Swift 6 严格并发下 `SwiftNft: Sendable` 编译不过（见 §5）。
- **SSRF（对齐 Kotlin `SsrfGuard` 语义 + Swift 修正 DNS rebinding）**：所有拉取 URL 过 `SsrfGuard.check`——scheme http/https、host 非空、**DNS 解析失败 fail-closed**、拒绝回环/私网/链路本地（含 `localhost`、10/8、192.168/16、172.16/12、169.254/16、::1、fe80::/10、fc00::/7），并补 IPv4-mapped IPv6（`::ffff:a.b.c.d`）、`0.0.0.0`/`255.255.255.255`、`100.64.0.0/10`（CGNAT）、`198.18.0.0/15`（基准测试）、`192.0.0.0/24`（IETF 协议保留）、`224.0.0.0/4` 组播 + `240.0.0.0/4` 保留、IPv6 `ff00::/8` 组播；**公网 IP 放行**（对齐 Kotlin 测试 8.8.8.8）。**Swift 修正（DNS rebinding / TOCTOU）**：Kotlin check 时解析一次、建连再解析一次，攻击者可「校验返回公网、建连返回私网」绕过；Swift 必须解析**全部**地址、任一私网即拒，建连策略三选一——**① Network.framework `NWConnection` 连已校验 IP + TLS server-name（证书仍按原主机名校验）；② 按主机名建连、连接建立后复验对端实际 IP；③ 明确接受残余 TOCTOU 风险并写入文档**（⚠️ 不能简单「pin IP + Host 头」，HTTPS 证书按主机名校验会失败，除非危险地 override server trust；**URLSession 无对端 IP API，方案 ② 仅 NWConnection 可行——用 URLSession 时只剩 ③（接受残余风险），要实现 ① 必须把拉取改用 `NWConnection` 承载**，详见 §4）。**默认取舍**：默认 `SwiftNftConfig.httpClient` 即 URLSession → 采用 ③（文档化残余风险）；威胁模型要求闭合 TOCTOU 时再切 `NWConnection` 实现 ①。`enabled` 旁路开关改 `internal` + `#if DEBUG`（非 public 可变全局）。
- **不跟随重定向（对齐 Kotlin）**：元数据/图片拉取 `instanceFollowRedirects = false` → Swift **delegate-backed URLSession**（`willPerformHTTPRedirection` 返回 nil）；**勿用 `URLSession.shared`**（无 delegate、会静默跟随）。**SWTC RPC 例外但需守重定向目标**：默认节点可跟随（对齐 Kotlin `instanceFollowRedirects = true`），但节点可注入后，`willPerformHTTPRedirection` 里必须对**新 URL 再查 `SsrfGuard`**，失败即不跟随——否则恶意节点 302 到私网地址即绕过守卫。
- **`data:` URL 支持（对齐 Kotlin）+ 决策收紧**：`isSupportedRemoteAssetUrl`（公开纯函数，对齐 Kotlin）仍放行任意 `data:`；解析路径在直出前用**独立的 `isDataImageUrl` 检查**仅放行 `data:image/*`（勿改动公开函数）——注意 `data:image/*` 只挡 HTML/JS，**挡不住 `image/svg+xml` 里的脚本**；`data:` 的 2 MiB 上限适用于**本模块解码校验**场景，原样透传时由渲染侧负责。**宿主渲染第三方图片必须用 `UIImage`/`CGImage` 解码（不执行脚本），勿用 `WKWebView`**。
- **`fetchMetadataFields` 非 Optional 语义**：失败返回 `NftMetadataFields.empty`，**不 throw**（对齐 `NftSdk`）；内部保留 throwing/Result 版本或日志区分「网络失败」与「字段缺失」，避免 `.empty` 掩盖节点故障（与 Did 三态 `DidResolveOutcome` 同思路）。
- **对 Kotlin 小怪癖的显式修正**：`hasLocal = !image.isNullOrBlank()`（Kotlin `image != null` 把空串也算 true）；`fetchAndCacheNftMeta` 失败路径记日志（scheme/host，不打 body），不静默吞错。
- **不记录 payload**：元数据 body 可能含隐私（头像、社交链接），日志只打 scheme/host，不打 body（对齐 DappConnect「日志不打 payload」约定）。
- **不面向 DApp 任意地址**：`getAvatarCandidates(account:)` 只接受**本钱包账户**（从本地持仓表读），杜绝 `eth_requestNfts` 式任意地址枚举（M3 边界）；`SwiftNft` 不暴露「按任意地址解析」的入口。
- **私钥无关**：本模块不接触私钥/秘钥，无桥传输面（与 SwiftWallet/SwiftDid 的密钥经桥风险隔离）。
