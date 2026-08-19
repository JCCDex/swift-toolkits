# 02 · Swift 版设计

## 1. 模块布局

```text
Sources/SwiftDid/
├── SwiftDid.swift            // 门面：生命周期 + 全部类型化 API（薄封装桥 + 服务编排）
├── Model/DidModels.swift     // Did / Profile / Nft / ProfileVC / VerificationMethod / DidEntity …
├── Model/CredentialModels.swift // UnifiedNftCredentialData / 校验结果 / VCID 结果 …
├── Model/NftModels.swift    // NFT 元数据 DTO：CredentialImageRequest / ResolvedCredentialImage /
│                            //   NftMetadataFields / DidAvatarAsset / NftMeta（镜像 Kotlin :nft 模型，
│                            //   阶段二随协议缝一并迁入 SwiftNft，见 Nft-Swift 02 §2）
├── Service/DidStore.swift    // DidStore 协议
├── Service/GRDBDidStore.swift // GRDB 实现（对应 Kotlin RoomDidStore）
├── Service/DidResolver.swift // IDidResolver 等价：resolve(did)（默认 = 桥调 didResolve），供 DidCoreService 注入/测试
├── Service/DidCoreService.swift // 观察/取档/写操作编排 + pending 对账状态机（对齐 Kotlin DidCoreService，见 01 §6）
├── Util/Keccak256.swift      // keccak-256（首选专门轻量依赖；自实现仅兜底，KAT 交叉验证，见 §7）
└── (无自有 JS：复用 SwiftWebviewBridge bundle 内 did-bridge.html / did-0.3.2.min.js)

# 预留：后续新增 Sources/SwiftNft/（镜像 Kotlin :nft），SwiftDid 以可选依赖接入
```

> **⚠️ 不复用 `WebviewBridgeEngine.shared`**：该单例已被 SwiftWallet 的 `wallet-bridge.html` 占用，
> 且一个 `WebviewBridgeClient` 只能承载一个 bridge 页面（`WebviewBridgeClient.start()` 对已有
> runtime 直接 return，换 config 也不会重载）。SwiftDid 必须**自持一个 `WebviewBridgeClient` 实例**
> 加载 `did-bridge.html`（对齐 Kotlin `AndroidDidWebRuntime` 的独立隐藏 WebView），见 §3。

`Package.swift` 依赖：

```swift
.target(
    name: "SwiftDid",
    dependencies: [
        .target(name: "SwiftWebviewBridge"),
        .target(name: "SwiftDappConnect"),   // DidSDK 协议定义于此
        .product(name: "GRDB", package: "GRDB")
    ],
    path: "Sources/SwiftDid"
)
// 包级依赖：GRDB 对应 Kotlin 的 Room（room-runtime / room-ktx）
.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
```

## 2. 模型（镜像 Kotlin，Codable）

```swift
public struct GenerateBase58PKResult: Codable, Sendable, Equatable {
    public let type: String
    public let publicKeyBase58: String
}

public struct PublishDidResult: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
}

public struct DidStatResult: Codable, Sendable, Equatable {
    public let cid: String?
}

public struct VerificationMethod: Codable, Sendable, Equatable {
    public let id: String
    public let controller: String
    public let type: String
    public let publicKeyBase58: String
    public let isSelf: Bool
}

public struct Did: Codable, Sendable, Equatable {
    public let id: String
    public let created: String
    public let updated: String
    public let verificationMethods: [VerificationMethod]
}

public struct Profile: Codable, Sendable, Equatable {
    public let nickname: String
    public let preferredAvatar: String
}

public struct DidEntity: Codable, Sendable, Equatable {
    public let did: String
    public let doc: String
    public let updatedAt: Int64   // 毫秒时间戳（Date().timeIntervalSince1970 * 1000）；id 主键保留在记录层（见 §4）
}

// NFT 展示模型（镜像 Kotlin `Nft` 8 字段，注意字段名 `contract` 而非 `contractAddress`）
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

// 展示模型（镜像 Kotlin `ProfileVC`）
public struct ProfileVC: Codable, Sendable, Equatable {
    public let nickname: String
    public let bio: String
    public let createdTime: String
    public let nft: Nft?
}

// 凭证模型（UnifiedNftCredentialData / CredentialVerificationResult /
// GranteeCredentialUpdateResult / QueryVcidResult / DidWriteResult …）逐一镜像。

// Swift 侧新增（非 Kotlin 镜像）：链上解析三态结果（见 04 坑 #15）。
// 桥/网络错误用独立 error 分支，不得伪装成 missing。
// 约定：resolveDid / DidCoreService.resolveAndSaveDid **不 throw**——所有失败统一进
// .error(Error)，由调用方按三态 switch 决策；throw 通道留给编程错误（参数非法等）。
public enum DidResolveOutcome {
    case missing
    case error(any Error)   // 桥/网络错误；携带 any Error，故不声明 Equatable/Sendable
    case document(String)   // 链上 DID 文档 JSON
}
```

## 3. SwiftDid（代码草案）

```swift
import Foundation
import SwiftWebviewBridge

/// 桥抽象（对应 Kotlin `IDidBridge`）：可注入 Fake 测试。
@MainActor
protocol DidBridge: AnyObject {
    func call(method: String, params: [String: Any]?) async throws -> String
    func callAs<T: Decodable>(method: String, params: [String: Any]?, as type: T.Type) async throws -> T
}

@MainActor
final class EngineDidBridge: DidBridge {
    /// 不复用 WebviewBridgeEngine.shared（已被 wallet-bridge 占用，单例只能承载一个页面）：
    /// 自持独立 client 加载 did-bridge.html，对应 Kotlin AndroidDidWebRuntime 的独立 WebView。
    private let client = WebviewBridgeClient()

    func start(ipfsBaseURL: String) throws {
        // 网关注入：校验 URL → 替换 did-bridge.js 占位符 → 临时 bundle 加载（见 03 §3 方案 A）。
        // 未配置 / URL 非法 / 占位符残留 → 抛 SwiftDidError.ipfsBaseURLNotConfigured（fail-closed）。
        // 临时 bundle 按「替换后内容 hash + ipfsBaseURL」缓存复用（见 04 坑 #22）。
        let bundle = try DidBridgeAssets.makeTempBundle(ipfsBaseURL: ipfsBaseURL)
        self.client.initialize(
            bundle: bundle,
            config: WebviewBridgeConfig(bridgeFileName: "did-bridge.html", resourceBundle: bundle)
        )
        try self.client.start()
    }

    func destroy() {
        self.client.destroy()  // 只销毁 DID 自己的 WebView，不影响 SwiftWallet 的共享引擎
    }

    func call(method: String, params: [String: Any]?) async throws -> String {
        try await self.client.callJsMethod(method: method, params: params)
    }
    func callAs<T: Decodable>(method: String, params: [String: Any]?, as type: T.Type) async throws -> T {
        try await self.client.callJsMethodAs(method: method, params: params, as: type)
    }
}

/// 链上解析抽象（对应 Kotlin `IDidResolver`，文件 `Service/DidResolver.swift`）：
/// 默认实现 = 桥调 `didResolve`；独立于 `DidBridge`，便于 `DidCoreService` 注入 Fake 测试。
/// 自由线程（不加 @MainActor，同 `DidStore`）；默认实现经 @MainActor 桥时异步 hop 到主 actor。
protocol DidResolver: AnyObject {
    func resolve(_ did: String) async throws -> String
}

@MainActor
public final class SwiftDid: DidSDK {
    private let bridge: any DidBridge
    private let store: any DidStore
    private let nft: (any DidNftResolution)?            // 预留：SwiftNft 模块接入点（未来）
    private let avatarResolver: (any DidAvatarResolver)? // 宿主注入头像解析（对齐 Kotlin IDidAvatarResolver）
    private let avatarCredentialSource: (any DidAvatarCredentialSource)? // 宿主头像候选源（对齐 Kotlin IDidAvatarCredentialSource）
    private let ipfsBaseURL: String?                    // 由宿主在 start() 前配置（无默认值，fail-closed）
    private var started = false
    public static let pendingTTLMillis: Int64 = 24 * 60 * 60 * 1000  // 24h，可配置（见 01 §6）

    public init(
        store: any DidStore,                        // 宿主提供 GRDBDidStore（或自实现）
        bridge: any DidBridge = EngineDidBridge(),
        ipfsBaseURL: String? = nil,                 // 必配：IPFS 网关（start() 前校验并注入）
        nft: (any DidNftResolution)? = nil,         // 预留：SwiftNft 模块接入点（未来）
        avatarResolver: (any DidAvatarResolver)? = nil, // 宿主注入（对齐 Kotlin IDidAvatarResolver）
        avatarCredentialSource: (any DidAvatarCredentialSource)? = nil // 宿主头像候选源
    ) {
        self.store = store
        self.bridge = bridge
        self.ipfsBaseURL = ipfsBaseURL
        self.nft = nft
        self.avatarResolver = avatarResolver
        self.avatarCredentialSource = avatarCredentialSource
    }

    // MARK: - 生命周期

    public func start() throws {
        guard !self.started else { return }
        // 网关注入：校验 ipfsBaseURL（仅 http/https，拒绝 javascript:/file:）→ 替换
        // did-bridge.js 占位符 → 临时 bundle 加载（见 03 §3 方案 A）；未配置/校验失败/
        // 占位符残留 → fail-closed。启动时顺带做一次 did_pending 全表 TTL 清理。
        guard let ipfsBaseURL, DidBridgeAssets.isValidBaseURL(ipfsBaseURL) else {
            throw SwiftDidError.ipfsBaseURLNotConfigured
        }
        try self.engineStart(ipfsBaseURL: ipfsBaseURL)
        try self.store.deleteExpiredPending(
            now: Int64(Date().timeIntervalSince1970 * 1000),
            ttlMillis: SwiftDid.pendingTTLMillis
        )
        self.started = true
    }

    // MARK: - DApp 签名面（SwiftDappConnect.DidSDK）

    /// 返回类型与 SwiftDappConnect.DidSDK 协议对齐（元组），避免同 selector 不同返回类型的重载冲突。
    public func didGenerateBase58PublicKey(privateKey: String) async throws -> (publicKeyBase58: String, type: String) {
        let r: GenerateBase58PKResult = try await self.callAs(method: "generatePublicKeyBase58", params: ["privateKey": privateKey])
        return (r.publicKeyBase58, r.type)
    }

    /// 只校验 VC 结构（对齐 Kotlin M-15 三条）；用户确认由宿主 UI 完成。
    public func signCredentialForDApp(privateKey: String, vcJson: String) async throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(vcJson.utf8)) as? [String: Any] else {
            throw SwiftDidError.invalidPayload
        }
        guard let credential = obj["credential"] as? [String: Any],
              (credential["@context"] != nil || credential["type"] != nil),
              credential["credentialSubject"] != nil,
              credential["issuer"] != nil || obj["issuerObject"] != nil
        else {
            throw SwiftDidError.invalidCredential
        }
        // JS signCredential 强依赖 keyDoc.did/id（见 03 §2），native 先于桥报错，避免透传桥内字符串错误。
        guard let keyDoc = obj["keyDoc"] as? [String: Any],
              (keyDoc["did"] as? String)?.isEmpty == false,
              (keyDoc["id"] as? String)?.isEmpty == false
        else {
            throw SwiftDidError.invalidCredential
        }
        var params = obj
        params["privateKey"] = privateKey
        return try await self.call(method: "signCredential", params: params)
    }

    public func ipfsGetPublicKey(privateKey: String) async throws -> String {
        try await self.call(method: "ipfsGetPublicKey", params: ["privateKey": privateKey])
    }

    public func ipfsPersonalSign(privateKey: String, data: [Int]) async throws -> String {
        try await self.call(method: "ipfsPersonalSign", params: ["privateKey": privateKey, "data": data])
    }

    // MARK: - DID 文档 / 写操作（服务层编排，见 DidCoreService）

    public func observeDidDocument(_ did: String) -> AsyncStream<DidEntity?> { ... }
    // 链上解析 + 落库 + 对账（委托 DidCoreService；内部经 DidResolver 纯链上解析）。
    // 三态结果：missing（链上缺失/已删除）/ error（桥或网络错误，不得伪装缺失）/ document（链上文档）。
    // 不 throw：失败统一进 .error，调用方按三态 switch 决策。
    public func resolveDid(_ did: String) async -> DidResolveOutcome { ... }
    public func publishDid(did: String, privateKey: String, didDocument: String) async throws -> PublishDidResult { ... }
    public func verifyCredential(_ credentialJson: String) async throws -> CredentialVerificationResult { ... }
    // 其余全量 API（对齐 Kotlin，签名见 01 §3）：toDid / formatAddress / nickname /
    // generateDid / generateProfileVC / generateSwtcNft / generateEthrNft / getAvatarNftCredentials /
    // readCredentials / checkGranteeCredentialUpdate / queryAndValidateVcid / bindVcidToDid /
    // updateDidAvatar / updatePreferredAvatar / addCredentialToDid / deleteCredentialFromDid /
    // uploadInitialDidDoc / updateDidNickname / publishDidDelete / resolveCredentialImage(s) 等
}

public enum SwiftDidError: Error, Equatable {
    case notInitialized
    case invalidPayload
    case invalidCredential
    case didNotFound
    case ipfsBaseURLNotConfigured
}
```

## 4. 存储（GRDB，对应 Kotlin Room）

```swift
/// 本地 DID 文档存储（对齐 Kotlin `IDidStore`）。Room 由 GRDB 替代。
/// 不加 @MainActor：读写走 GRDB 后台调度，避免阻塞主线程（Kotlin `IDidStore` 方法同为 suspend）。
public protocol DidStore: AnyObject {
    func observeAll() -> AsyncStream<[DidEntity]>
    func observe(_ did: String) -> AsyncStream<DidEntity?>
    func getDidDocument(_ did: String) async throws -> DidEntity?
    func saveDidDocument(_ did: String, doc: String) async throws
    func deleteDidDocument(_ did: String) async throws

    // pending 对账状态（Swift 增强：持久化消除重启窗口）。DidCoreService 必须经此读写，
    // 否则对账状态机无法注入 Fake、宿主也无法替换存储（见 01 §6 与 04 章坑 #16）。
    func savePending(_ pending: DidPending) async throws          // upsert-by-(kind,did)，不刷新 updatedAt
    func loadPending(did: String) async throws -> [DidPending]
    func deletePending(kind: String, did: String) async throws
    func deleteExpiredPending(now: Int64, ttlMillis: Int64) async throws
}

/// pending 对账记录（对应 Kotlin DidCoreService 的四张 ConcurrentHashMap，见 01 §6）。
public struct DidPending: Codable, Sendable, Equatable {
    public let kind: String      // create / avatar / nickname / delete
    public let did: String
    public let value: String?    // kind 相关负载（avatar→preferredAvatar、nickname→nickname、
                                 // delete→updated 时间戳；create 为 nil）
    public let updatedAt: Int64  // 写入时间（毫秒），TTL 以首次写入为基准、不续期
}

/// GRDB 记录（对应 Kotlin `DidRoomEntity`）：保留自增 `id` 主键（对齐 Room），
/// 同时给 `did` 加 UNIQUE 索引，保证「并发 upsert 取最新」。
private struct DidRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?   // AUTOINCREMENT 主键（对外 `DidEntity` 不暴露）
    var did: String
    var doc: String
    var updatedAt: Int64

    static let databaseTableName = "did_documents"
}

/// pending 对账记录（对应 Kotlin DidCoreService 的四张 ConcurrentHashMap，见 01 §6）。
/// 持久化到 GRDB 以消除重启窗口；`value` 存 kind 相关负载（avatar→preferredAvatar、
/// nickname→nickname、delete→updated 时间戳；create 为 nil）。
private struct DidPendingRecord: Codable, FetchableRecord, PersistableRecord {
    var kind: String      // create / avatar / nickname / delete
    var did: String
    var value: String?    // kind 相关负载
    var updatedAt: Int64  // 写入时间，供 TTL 过期清理（见 01 §6 注意）
    static let databaseTableName = "did_pending"
}

/// GRDB 实现（对应 Kotlin `RoomDidStore` + `DidRoomDatabase`）：
/// `did_documents` 表（id INTEGER PK AUTOINCREMENT / did UNIQUE / doc / updated_at），
/// ValueObservation 驱动观察流。
public final class GRDBDidStore: DidStore {
    private let database: DatabasePool    // 观察流与写并发并存，直接上 Pool + WAL，避免事后迁移成本

    public init(database: DatabasePool) throws {
        self.database = database
        try self.migrate()   // DatabaseMigrator：建表（对齐 Room 建表语义）
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "did_documents") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("did", .text).notNull().unique()
        t.column("doc", .text).notNull()
        t.column("updatedAt", .integer).notNull()
            }
            try db.create(table: "did_pending") { t in
                t.column("kind", .text).notNull()
                t.column("did", .text).notNull()
                t.column("value", .text)
                t.column("updatedAt", .integer).notNull()
                t.primaryKey(["kind", "did"])   // 同一 (kind, did) 只保留一条 pending
            }
        }
        try migrator.migrate(self.database)
    }

    public func observeAll() -> AsyncStream<[DidEntity]> {
        // ValueObservation.tracking { db in
        //   try DidRecord.order(Column("updatedAt").desc).fetchAll(db)   // O3：按 updatedAt 倒序
        // }.values(in: database) → AsyncStream（后台调度）
    }

    public func observe(_ did: String) -> AsyncStream<DidEntity?> {
        // ValueObservation.tracking { db in try DidRecord.filter(Column("did") == did).fetchOne(db) }
        //   .values(in: database) → AsyncStream（GRDB Observation 天然支持 async sequence，后台调度）
        // O4：元素在数据库队列交付，SwiftUI 消费需 `Task { @MainActor in … }` 跳主线程
    }
    // … save 用 INSERT … ON CONFLICT(did) DO UPDATE（upsert-by-did，id 由记录层自增）
    //   get/delete 用 read/asyncWrite（后台）；写后自动重放观察流
}
```

> 选型说明：**GRDB 是 Swift 生态的 Room 等价物**（类型安全查询、迁移、ValueObservation→AsyncStream 原生桥接），
> 替换 Kotlin 的 Room `Entity/DAO/Database` 三层；`DidStore` 协议保留，宿主仍可自实现替换。
> 数据库文件默认 `Application Support/Did/did.sqlite`（同 SwiftVault 的文件位置约定）。
> **存储选型修正**：观察流 + 写操作并存时直接用 `DatabasePool`（WAL），不要「默认 Queue、高并发再换」——
> 换 Pool 涉及迁移与并发语义复核，事后成本更高。
>
> **`id` 主键保留在记录层**：`DidRecord` 用自增 `id` 作主键（对齐 Room `@PrimaryKey(autoGenerate)`），
> 同时给 `did` 加 UNIQUE 索引，`save` 走 `INSERT … ON CONFLICT(did) DO UPDATE`（upsert-by-did），
> 等价 Kotlin `observeByDid` 的 `ORDER BY updatedAt DESC, id DESC LIMIT 1`「并发取最新」语义；
> 对外 `DidEntity` 不暴露 `id`，`DidStore` 签名不变。
>
> **`did_pending` 表（持久化对账状态）**：见 01 §6 的 Swift 增强；`(kind, did)` 联合主键，`value` 存
> kind 相关负载，`updatedAt` 供 TTL 过期清理（publish 失败会永久滞留，见 01 §6 注意）。
> **upsert 保留 `updatedAt`**：写 pending 用 `INSERT … ON CONFLICT(kind, did) DO UPDATE SET value = excluded.value`
> （**不动 `updatedAt`**），保证「首次写入为基准、不续期」——否则连续两次改同字段会悄悄续命 TTL。清理不启动定时器：
> `resolveAndSaveDid` 按 did 顺带删过期行 + 迁移后启动全表清理。

## 5. 对接 SwiftDappConnect

```swift
// SwiftDid 直接声明 `public final class SwiftDid: DidSDK`（见 §3）。
// 四个方法签名与协议完全一致（base58 返回元组、其余返回 String），
// 无需再写包装 extension——否则同名不同返回类型会编译冲突、且自我递归。
```

## 6. avatar/NFT 解析（预留 SwiftNft 接入点）

对齐 Kotlin 的回退链（`avatarResolver → nftSdk → buildSwtcNft/buildEthrNft`）：

```swift
/// 头像/NFT 解析能力（宿主可注入；未来由 SwiftNft 模块实现）。
/// 覆盖 Kotlin `NftSdk` 的完整方法面（14 个公开方法 = 13 个方法名 + resolveCredentialImage 重载，
/// 含 fetchAndCacheNftMeta），未接入前返回 nil/空，保证 API 不变、后续无缝接入。
/// 纯数据取/解析（无 UI），不加 @MainActor（同 `DidStore` 自由线程调度）。
public protocol DidNftResolution: AnyObject {
    // 头像解析（对齐 Kotlin IDidAvatarResolver）
    func resolveSwtcAvatar(vc: String) async -> Nft?
    func resolveEthrAvatar(vc: String) async -> Nft?
    // 头像候选（对齐 IDidAvatarCredentialSource / nftSdk.getAvatarCandidates）
    func getAvatarCandidates(account: WalletAccount) async -> [DidAvatarAsset]
    // 元数据预取缓存（Kotlin NftSdk.fetchAndCacheNftMeta；generateProfileVC 依赖，缺了「不裁剪」不成立）
    func fetchAndCacheNftMeta(contract: String, tokenId: String, tokenUri: String) async -> NftMeta?
    // 返回 NftMeta?（对齐 Kotlin NftSdk 返回 Room 实体 NftMetaEntity?）；NftMeta 定义见 NftModels.swift

    // NFT 元数据面（Kotlin `NftSdk` 其余方法；预留，SwiftNft 未接入前返回 nil/空）
    func resolveCredentialImage(_ imageUrl: String?, metadataUri: String?) async -> String?
    func resolveCredentialImage(_ request: CredentialImageRequest) async -> ResolvedCredentialImage?
    func resolveCredentialImages(_ requests: [CredentialImageRequest]) async -> [ResolvedCredentialImage?]
    func fetchResolvedMetadataImage(_ metadataUrl: String) async -> String?
    func normalizeAssetUrl(_ rawUrl: String?, baseUrl: String?) -> String?
    func extractResolvedMetadataImageUrl(_ body: String, metadataUri: String) -> String?
    func isSupportedRemoteAssetUrl(_ url: String?) -> Bool
    func extractSwtcMetadataUri(_ payload: String?) -> String?
    func fetchMetadataFields(_ metadataUri: String) async -> NftMetadataFields   // 非 Optional，对齐 Kotlin
    func ensureSwtcCredentialMetadata(_ vc: String) async
}

// 宿主头像解析注入点（对齐 Kotlin IDidAvatarResolver，独立于 SwiftNft 模块）：
public protocol DidAvatarResolver: AnyObject {
    func resolveSwtcAvatar(vc: String) async -> Nft?
    func resolveEthrAvatar(vc: String) async -> Nft?
}

// 宿主头像候选源（对齐 Kotlin IDidAvatarCredentialSource，独立于 SwiftNft 模块）：
// 供 getAvatarNftCredentials(account) 走宿主自有 NFT 库，避免耦合 App DB schema。
public protocol DidAvatarCredentialSource: AnyObject {
    func getAvatarCandidates(account: WalletAccount) async -> [DidAvatarAsset]
}

// 上文中 `DidAvatarAsset` / `CredentialImageRequest` / `ResolvedCredentialImage` /
// `NftMetadataFields` 等 NFT 元数据 DTO **定义在 SwiftDid（Model/NftModels.swift，镜像 Kotlin :nft 模型）**——
// Swift 协议方法签名一旦引用类型，该类型必须对协议所在模块可见，故 DTO 前置到 SwiftDid，
// 未来 `SwiftNft` 模块直接复用这些值类型（纯 Codable DTO，无耦合）。

// SwiftDid 内：
private func resolveAvatar(vc: String) async -> Nft? {
    // 1) 宿主注入的 resolver
    if let nft = await self.avatarResolver?.resolveEthrAvatar(vc) ?? self.avatarResolver?.resolveSwtcAvatar(vc) {
        return nft
    }
    // 2) 未来 SwiftNft 模块（nft 参数）
    if let nft = await self.nft?.resolveEthrAvatar(vc) ?? self.nft?.resolveSwtcAvatar(vc) {
        return nft
    }
    // 3) 本地兜底（buildSwtcNft / buildEthrNft，读 VC 字段）
    return self.buildLocalNft(vc)
}
```

> 未接入任何 resolver 时相关方法返回 nil/空，协议缝保留；后续新增 `Sources/SwiftNft/` 后只需在构造时传入，不改 SwiftDid API。

## 7. 并发与安全要点

- **线程模型（门面 + 编排 @MainActor，I/O 协议自由线程）**：`SwiftDid` 门面与 `DidCoreService` 编排层保持 **@MainActor**（桥调用免 hop、pending 对账互斥简单）；`DidStore` / `DidResolver` / `DidNftResolution` / `DidAvatarResolver` / `DidAvatarCredentialSource` 协议**自由线程**（不加 @MainActor），实现内部自行调度（GRDB 后台队列、桥 hop 主 actor），避免编排层线程切换地狱。
- **结构校验边界（M-15）**：`signCredentialForDApp` 仅校验 `credential` 结构；签名确认必须由宿主弹 UI，SDK 不内置（避免破坏性回调 API）。
- **私钥 String 传输**：同 `SwiftWallet`，私钥经 JS 桥以 String 传递，调用后尽快丢弃引用。
- **EIP-55 checksum（keccak-256，首选专门轻量依赖）**：`toDid` / VCID 生成需要 keccak-256，CryptoKit 不提供。**优先专门的轻量 keccak 依赖**（避免为单个算法引入整个 CryptoSwift；`swift-crypto`/CryptoKit 也不含 keccak-256；若选 CryptoSwift 须仅取 Keccak variant——0x01 padding 的 Keccak-256，非 SHA3-256）；确需自实现 `Util/Keccak256.swift` 时，必须与 BouncyCastle 做 KAT 全量交叉验证并固定进 CI（仅 `""`/`"abc"` 两条标准向量不够）。
- **`updated` 时间戳比较（勿照搬 Kotlin 字符串比较）**：链上 `updated` 解析为 ISO8601 `Date`（开 `.withFractionalSeconds`，处理不定长小数位）后比较，测试覆盖精度不一致场景（如 `…0.12Z` vs `…0.1Z`）。
- **`didStat` 失败 = 发布失败（有限重试）**：previousCid 取不到时先有限重试（1–2 次）再中止发布并上抛，避免 IPFS 历史链分叉（Kotlin 静默吞错，见 01 §6）。
- **`resolveAndSaveDid` 返回类型化结果**：区分 `missing / error / document`，桥/网络错误不得伪装成「链上缺失」，否则 `resolveOwnerDidDocument` 会静默回退本地陈旧缓存。
- **文档键名归一化**：写 `service` 前删除旧 `services` 键（反之亦然），避免同一文档出现双键（Kotlin 现状缺陷，见 01 §6）。
- **`verifyCredential` 保留 `errorKind`/`error`**：JS 返回里含失败原因（撤销/签名无效等），Kotlin 丢弃了；Swift 模型带上，供宿主展示验签失败原因。
