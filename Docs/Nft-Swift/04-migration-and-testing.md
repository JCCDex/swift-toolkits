# 04 · 迁移与测试

> 对齐依据：`kotlin-toolkits` commit `f77b59f`（`nft/src/test/java/com/jccdex/toolkits/nft/`）。本文的「坑」均来自源码实况核对，不再标注推断。

## 1. Kotlin → Swift 逐项对照（NftSdk 14 公开方法）

| Kotlin `NftSdk` | Swift `SwiftNft` | 说明 |
| --- | --- | --- |
| `suspend fun getAvatarCandidates(account): List<AvatarCandidate>` | `getAvatarCandidates(account: WalletAccount) async -> [DidAvatarAsset]` | 本地持仓表读候选；类型合并见 02 §2 |
| `suspend fun resolveSwtcAvatar(vc): Nft?` | `resolveSwtcAvatar(vc: String) async -> Nft?` | 回退链 01 §4.2 |
| `suspend fun resolveEthrAvatar(vc): Nft?` | `resolveEthrAvatar(vc: String) async -> Nft?` | 回退链 01 §4.3 |
| `suspend fun ensureSwtcCredentialMetadata(vc)` | `ensureSwtcCredentialMetadata(_ vc: String) async` | VC tokenId/nftIssuer → 预取 |
| `suspend fun fetchAndCacheNftMeta(contract, tokenId, tokenUri): NftMetaEntity?` | `fetchAndCacheNftMeta(contract:tokenId:tokenUri:) async -> NftMeta?` | 落 `nft_meta` 表（含 fullContent） |
| `suspend fun resolveCredentialImage(imageUrl, metadataUri): String?` | `resolveCredentialImage(_:metadataUri:) async -> String?` | 重载 ①，`String?` |
| `suspend fun resolveCredentialImage(request): ResolvedCredentialImage?` | `resolveCredentialImage(_ request:) async -> ResolvedCredentialImage?` | 重载 ②，`url`+`cacheKey` |
| `suspend fun resolveCredentialImages(requests): List<ResolvedCredentialImage?>` | `resolveCredentialImages(_:) async -> [ResolvedCredentialImage?]` | 按解析键去重 |
| `suspend fun fetchResolvedMetadataImage(metadataUrl): String?` | `fetchResolvedMetadataImage(_:) async -> String?` | 拉元数据提图（记忆化） |
| `fun normalizeAssetUrl(rawUrl, baseUrl = null): String?` | `normalizeAssetUrl(_:baseUrl: = nil) -> String?` | **同步**纯函数 |
| `fun extractResolvedMetadataImageUrl(metadataBody, metadataUri): String?` | `extractResolvedMetadataImageUrl(_:metadataUri:) -> String?` | **同步**纯函数 |
| `fun isSupportedRemoteAssetUrl(url): Boolean` | `isSupportedRemoteAssetUrl(_:) -> Bool` | **同步**纯函数（http/https/data:） |
| `fun extractSwtcMetadataUri(tokenInfosPayload): String?` | `extractSwtcMetadataUri(_ tokenInfosPayload: String?) -> String?` | **同步**纯函数（hex 解码） |
| `suspend fun fetchMetadataFields(metadataUri): NftMetadataFields` | `fetchMetadataFields(_:) async -> NftMetadataFields` | **非 Optional**（对齐 NftSdk） |

> 与 Kotlin 差异：`suspend` → `async throws`（非 Optional/同步纯函数除外）、Gson/org.json → `JSONDecoder`、Room → GRDB、`HttpURLConnection` → `URLSession`（行为对齐，见 02 §4）、`NftMetadataImageCache`（ConcurrentHashMap+Mutex）→ actor。

## 2. 实现注意点 / 坑

1. **DTO 归属迁移（对 Did 设计稿的显式修正）**：Kotlin 实况是 `:did → :nft`（`did/build.gradle.kts` `implementation(project(":nft"))`）；Did 设计稿写「SwiftNft 复用 SwiftDid 的 DTO」照做会得到反向依赖（拖入桥 + GRDB）。**两阶段执行**：阶段一 DTO 与协议缝在 SwiftDid（编译期可用）；阶段二 DTO **与 `DidNftResolution` 协议缝一并迁入 SwiftNft** + SwiftDid `public typealias`（含协议，见 02 §2 与坑 #19）。**别把 `Nft`/`DidAvatarAsset` 留在 SwiftDid**：DTO 与协议都在 SwiftNft 后，SwiftNft conform 无需访问 SwiftDid，依赖才无环。
2. **合并偏离落地校验（双 Nft / AvatarCandidate↔DidAvatarAsset）**：Kotlin 中 `:did.Nft`↔`:nft.Nft`、`AvatarCandidate`↔`DidAvatarAsset` 字段完全一致（`toDidNft()`/`toDidAvatarAsset()` 逐字段拷贝）。Swift 合并为单类型前，**落地时做字段对照表校验**（8 字段逐项比对）；若上游后续给两类型加差异字段，立即拆回双类型。
3. **Room → GRDB 四表**：`nft_meta`（自增 id + `(contract, tokenId)` UNIQUE）、`swtc_nfts`（`(ownerAddress, tokenId)` 复合 PK）、`evm_nft_items`（四列复合 PK）、`evm_nft_collections`（三列复合 PK）逐一镜像（`DatabaseMigrator` 建表）。**查询 LOWER() 归一化**（address/contract）照搬 DAO SQL（`observeEvmNftItems` 等）；`upsert` 用 **`INSERT ... ON CONFLICT(...) DO UPDATE`（`.upsert`）**，不用 `INSERT OR REPLACE`——REPLACE 删旧插新会让 `nft_meta` 自增 id 变化（Kotlin 为此手动 `copy(id=existing.id)`），且有四表行替换副作用。**`deleteSwtcNftsByOwner` 必须先 `preserveSwtcEntityAsMeta`**（有 `metadataUri` 的行写进 `nft_meta`，否则头像元数据随持仓删除丢失）。
4. **SsrfGuard 的 DNS fail-closed 别做漏 + 修 DNS rebinding（TOCTOU）**：Swift 用 `getaddrinfo`/Network 框架解析 host，**解析失败 = 拒绝**（Kotlin 测试：`http://this-host-should-not-resolve.invalid/metadata` 拒绝）；回环/私网/链路本地拒绝（`localhost`、10/8、192.168/16、172.16/12、169.254/16、::1、fe80::/10、fc00::/7），并补 IPv4-mapped IPv6（`::ffff:a.b.c.d` 映射回 IPv4）、`0.0.0.0`/`255.255.255.255`、`100.64.0.0/10`（CGNAT）、`198.18.0.0/15`（基准测试）、`192.0.0.0/24`（IETF 保留）、`224.0.0.0/4` 组播 + `240.0.0.0/4` 保留、IPv6 `ff00::/8` 组播；**公网 IP 放行**（8.8.8.8 通过——别误做成「裸 IP 全拒」）。**Kotlin 缺陷（勿照搬）**：`SsrfGuard.check` 解析一次、`openConnection` 再解析一次，攻击者可控域名可「校验公网、建连私网」绕过——Swift 必须 ① 解析**全部**地址、任一私网即拒；② 建连策略三选一（**HTTPS 不能简单「pin IP + Host 头」**，证书按主机名校验会失败）：a) `NWConnection` 连已校验 IP + TLS server-name（证书按原主机名校验）；b) 按主机名建连后复验对端实际 IP；c) 接受残余 TOCTOU 风险并写入文档。**⚠️ URLSession 不暴露对端实际 IP（无 peer-address API），方案 b 只对 NWConnection 可行**——用 URLSession 时只能在 a 与 c 之间选。`enabled` 旁路开关改 `internal` + `#if DEBUG`（勿做 public 可变全局）。
5. **`fetchMetadataFields` 可空性**：`NftSdk` 非 Optional（失败返回 `NftMetadataFields(null,null,null)`）；但 Kotlin **`DidSdk` 包装方法返回 `NftMetadataFields?`**。Swift 协议缝沿用非 Optional（对齐 NftSdk），是显式偏离——若日后要严格镜像 `DidSdk`，改 Optional 会改协议缝，须先与 Did 设计稿同步。
6. **缓存语义（成功才缓存）**：`NftMetadataImageCache` 只缓存**成功**结果；HTTP 500 等瞬时失败不缓存、下次可重试（Kotlin 测试 `resolveCredentialImage retries metadata fetch after a transient failure`：先 500 后 200，第一次 null、第二次成功、请求数 2）。Swift actor 实现别把失败结果写进字典。`nft_meta`/图片缓存**无 TTL**（对齐 Kotlin）；`removeAll()` 供宿主清理。
7. **不跟随重定向**：元数据/图片拉取必须关闭重定向（**delegate-backed URLSession** `willPerformHTTPRedirection` 返回 nil；对齐 Kotlin `instanceFollowRedirects = false`）——**勿用 `URLSession.shared`**（无 delegate、会静默跟随，重定向是 SSRF 绕过路径）；**SWTC RPC 例外**：节点可信、跟随重定向（对齐 Kotlin `instanceFollowRedirects = true`；`SwtcTokenUriResolver` 无 delegate，见偏离 #36）。测试覆盖：元数据 URL 302 → 失败。
8. **`data:` URL 支持（对齐 Kotlin）+ 上限增强 + 类型决策**：`isSupportedRemoteAssetUrl` 放行 `data:`（对齐 Kotlin 纯函数）；Swift 解码 `data:` 时加 2 MiB 上限（Kotlin 无上限属现状，Swift 增强防膨胀；上限适用于**本模块解码校验**，原样透传时由渲染侧负责）。**类型面（设计决策）**：`resolveCredentialImage` 直出前用**独立的 `isDataImageUrl` 检查**仅放行 `data:image/*`（公开 `isSupportedRemoteAssetUrl` 仍对齐 Kotlin、放行任意 `data:`）——只挡 HTML/JS，**挡不住 `image/svg+xml` 脚本**；宿主渲染第三方图片须用 `UIImage`/`CGImage`（不执行脚本）、勿用 `WKWebView`。
9. **`normalizeRemoteAssetUrl` 细节别照旧草案**：① 无 base 的不可解析路径**返回原样**（不判 nil）；② http(s) 路径含 `/ipfs/` **强制换默认网关**（`canonicalizeHttpIpfsUrl`）——**网关可注入后该行为可能误伤第三方 URL**（如 `https://cdn.thirdparty.com/ipfs/xyz`），保持 Kotlin 行为或限定已知 IPFS 网关域名，二选一固化（见 03 §4.2）；③ 裸 CID（`Qm`/`bafy` 前缀）→ 网关；④ 以 `{`/`[` 开头的 payload → nil；⑤ 相对路径用 `URL(URL(base), raw)` **标准解析**（含协议相对 `//host/…`）；⑥ **可注入网关贯穿所有 normalize 调用点**：`normalizeRemoteAssetUrl`/`canonicalizeHttpIpfsUrl` 以及内部调 normalize 的 `extractMetadataImageUrl` 都带 `gateway` 参数（默认 defaultGateway），门面把 `config.ipfsGateway` 传入，否则「可注入网关」只对 `IpfsResolver.rewrite` 生效、ipfs:// 重写仍硬编码默认网关（见 02 §4）。
10. **SWTC `erc_info` RPC**：POST `{"method":"erc_info","params":[{"tokenid":tokenId}]}`；`TokenInfos` 可能是数组**或字符串**（两种都处理）；`extractSwtcMetadataUri` 只认 hex 解码后 `InfoType == "tokenUri"` 的项；**节点由 `getRpcNode` 注入（单 URL）**，`fetchMetadataUri` 不再遍历节点列表；可选证书 pinning（SHA-256/Base64，Swift 用 `URLSessionDelegate` 的 `didReceive challenge` 实现）。**⚠️ pin 口径偏离 Kotlin**：Swift hash 原始公钥字节（`SecKeyCopyExternalRepresentation`），Kotlin hash SPKI DER（`cert.publicKey.encoded`），两者不互通——宿主按 Swift 口径生成 pin，或改 SPKI 提取（ASN.1）再对齐 Kotlin。
11. **`IEthTokenUriResolver` 非 throw**：签名 `resolveEthrTokenUri(...) async -> String?`（失败返回 nil）；Swift 实现/宿主实现都别用 throw 通道。**模块内默认实现（`Net/EthTokenUriResolver.swift`，实现回写 #31）**：SwiftNft 随包提供 eth_call 默认解析器（ERC-721 `tokenURI(uint256)`，selector `0xc87b56dd`；calldata 只拼 32 字节十进制 tokenId、合约地址走 `to` 字段；ABI string 解码假定 offset=32；URI 过 `normalizeRemoteAssetUrl`）；**RPC 端点不内置**，由 `init(getRpcNode:)` 注入「chainId → RPC URL」函数（对齐 Kotlin `defaultRpcUrlsForChain`/`AppEndpoints.RPC_*` 由宿主配置的语义），返回 nil → nil（单节点 eth_call，非 throw）。
12. **`resolveCredentialImages` 去重**：按 `buildCredentialResolutionKey`（chainId|contract.lowercase()|tokenId|normalize(metadataUri)|normalize(imageUrl, metadataUri)）用 LinkedHashMap 等价物去重——**相同请求只拉一次**（Kotlin 测试锁定：2 个相同请求 → 1 次 server 请求、2 个相等结果）；空列表直接返回空。
13. **日志不落 payload**：元数据 body 可能含头像/社交链接等隐私，日志只打 scheme/host（对齐 DappConnect「日志不打 payload」约定）。
14. **与 SwiftDappConnect `NftProvider` 的边界别串**：`eth_requestNfts` / `swtc_requestNfts`（DApp 面持仓枚举、`{address,total,nfts}` 序列化）属宿主 `NftProvider`；SwiftNft 的存储/客户端可**支撑**宿主实现，但 M3（任意地址枚举）在 `NftProvider` 侧修（address ∈ 已授权账户），SwiftNft 侧无此面。
15. **模型依赖**：`WalletAccount`/`ChainType` 在 Kotlin 属 `:core`，Swift 已存于 SwiftDappConnect（零运行时依赖），SwiftNft 依赖它仅取模型；`ChainType.evmChainId` 决定 EVM 候选链（nil → 空列表，对齐 Kotlin）。
16. **`NftMetadataImageCache` 的 in-flight 去重别用裸 actor**：同 key 并发要只 fetch 一次（Kotlin 用 per-key Mutex），Swift 用 **per-key 的 `Task` 缓存**（`[String: Task<String?, Never>]`）——若只在 actor 方法内 `await fetch()`，会跨网络调用持有 actor、**所有 key 全局串行**；若把 fetch 放 actor 外，两个同 key 并发调用会各拉一次（无去重）。落地写清楚 in-flight 去重路径；**`removeAll()` 必须取消并丢弃 inflight 里所有 Task 并清空两字典**，否则切账户后旧请求继续回写缓存。**并发失败语义微偏离（显式接受，Swift 更优）**：Kotlin 的 Mutex 在并发失败（null 不缓存）时第二个调用者会**重新 fetch**（N 并发 = N 次拉取），Swift per-key Task 让并发调用者**共享同一个 null**（1 次拉取）——勿为「对齐 Kotlin」复刻重复拉取。
17. **`resolveCredentialImages` 的 nil 去重语义**：Kotlin `getOrPut` 会把**失败（null）也缓存**进同批去重表，同批重复键的失败请求不重拉；Swift 用 `[String: ResolvedCredentialImage?]` 表达「按 key 是否存在去重」。**技术细节（勿踩）**：`dict[key]` 是 `ResolvedCredentialImage??`（双重 Optional），`if let v = dict[key]` 只解一层——key 存在且值为 nil 时**仍会命中**（`v == nil`），并没有「把 nil 误判成未命中」的问题；真正会踩的写法是：① 显式单层类型标注 `if let v: ResolvedCredentialImage = dict[key]`（强制解两层，nil 值判未命中）；② 任何拍扁双重 Optional 的写法（`dict[key] ?? nil` / `flatMap { $0 }`）；③ 用 `dict[key] == nil` 判断「未命中」（key 存在但值为 nil 时 `.some(nil) == nil` 为 false，语义反直觉）。**推荐仍用 `dict.index(forKey:)`**（见 02 §6 代码）——语义显式、不依赖双重 Optional 规则。
18. **可注入 `swtcTokenUriResolver`/`ipfsGateway` 的信任边界**：Kotlin 硬编码可信节点/网关故不查 SsrfGuard；Swift 增强为可注入，建连前对注入值做 `SsrfGuard.check`（http/https + 公网），否则「注入节点 + 跟随重定向」= SSRF。`enabled` 旁路开关改 `internal` + `#if DEBUG`，勿做 public 可变全局。
19. **依赖环（对 02 §2 的补强）**：`DidNftResolution` 协议缝现定义在 SwiftDid；阶段二**必须随 DTO 一起迁入 SwiftNft**（14 方法签名不动），SwiftDid 用 `public typealias DidNftResolution = SwiftNft.DidNftResolution` 保公开拼写——否则 SwiftNft conform 该协议需 `import SwiftDid`，`SwiftDid → SwiftNft → SwiftDid` 成环。
20. **`Sendable`（Swift 6 严格并发）**：`NftStore: AnyObject, Sendable`；`GRDBNftStore: NftStore, @unchecked Sendable`（DatabasePool 线程安全）。否则 `SwiftNft: Sendable` / `SwiftNftConfig: Sendable` 持有 `any NftStore` 编译不过。
21. **对 Kotlin 小怪癖的显式修正**：① `hasLocal = !image.isNullOrBlank()`（Kotlin `image != null` 把空串算 true，勿照搬）；② `fetchAndCacheNftMeta` 失败路径记日志（scheme/host，不打 body），不静默吞错（Kotlin catch-all 返回 null 无日志）；③ `fetchMetadataFields` 对外非 Optional/.empty，内部保留 throwing/Result 版本或日志区分「网络失败」与「字段缺失」。
22. **`SwtcTokenUriResolver` 抽协议 seam**：① 抽 `ISwtcTokenUriResolver` 协议、`SwiftNftConfig` 注入 `swtcTokenUriResolver`（宿主注入 `SwtcTokenUriResolver(getRpcNode:)` 或自实现/Fake；nil → SWTC 解析返回 nil，config 不再内置节点/建默认实现）——否则「Fake SwtcTokenUriResolver」测试落不了地（对齐 Kotlin 构造函数注入）；② 网络走 `NftHttpClient.fetchRpc`（POST + 跟随重定向；`URLSessionNftHttpClient` 自持 RPC session，见偏离 #37）。

## 3. 测试策略

| 层级 | 方式 | 覆盖 |
| --- | --- | --- |
| URL 纯函数 | `NftUrlUtilsTests`（macOS `swift test`） | `normalizeAssetUrl` KAT（Kotlin 向量：`ipfs://bafy123/avatar.png` → `https://ipfs.jccdex.cn/ipfs/bafy123/avatar.png`、`"assets/avatar.png"` + base → join、`/ipfs/` 前缀、裸 CID、`data:` 透传、JSON-looking 拒、无 base 原样、http `/ipfs/` 换网关、**自定义网关贯穿**：`normalizeRemoteAssetUrl`/`canonicalizeHttpIpfsUrl` 带 `gateway:` 时 `ipfs://` 与 `/ipfs/` 重写到自定义网关）；`isSupportedRemoteAssetUrl`（http/https/data: true；`ipfs://` false）；`extractResolvedMetadataImageUrl`（键顺序 image/image_url/imageUrl、`data` 解包、畸形 JSON）；`extractSwtcMetadataUri`（hex 向量 `746f6b656e557269`/`697066733a2f2f…`） |
| 元数据解析 | `NftMetadataParserTests` | `fetchMetadataFields`（`data` 解包、相对图片 join、缺字段 → 空结构、失败不 throw） |
| SSRF | `SsrfGuardTests` | 镜像 Kotlin `NftRemoteAssetResolverTest`：loopback/site-local/link-local 拒、**公网 IP 放行**、file:/javascript:/ftp 拒、非 http(s) scheme 拒、**未解析域名 fail-closed**、`enabled=false` 旁路；**全地址解析（任一私网即拒）**、IPv4-mapped IPv6、fc00::/7、建连策略（连 IP + TLS server-name 或建连后复验） |
| 网络层 | Fake `NftHttpClient` + URLProtocol 少量用例 | `resolveCredentialImage` 四分支（内联 JSON 提图 / 直出 / metadataUri 即图片 URL / 拉元数据提图）；**瞬时失败重试**（500 → nil，再调成功）；`resolveCredentialImages` 去重（1 次请求）；**不跟随重定向**（302 → 失败）；**RPC 重定向目标被 `SsrfGuard` 拒绝**（302 到私网不跟随）；`data:` 超上限截断、非 `data:image/*` 拒 |
| 缓存 | `NftMetadataImageCacheTests` | 成功记忆化、**失败不缓存（可重试）**、并发同 key 只 fetch 一次（**per-key Task in-flight 去重**）、`removeAll`（取消在途 Task + 清空两字典） |
| EVM tokenURI | `EthTokenUriResolverTests` | `buildTokenUriCallData` KAT（十进制 tokenId → `0xc87b56dd` + 32B hex：`"4"` → `…04`、大数 `2^256-1` → 64 位全 `f`、超 32 字节拒、非数字拒）、`decodeAbiString`（"hi"/URI ABI 向量、超短/空/畸形拒、尾随垃圾截断）、`normalizeTokenMetadataUri`（ipfs:// → 默认网关、http 原样、空白 → nil） |
| 存储 | `GRDBNftStore`（内存 DatabasePool） | 四表建表迁移、upsert/observe/get/delete、复合 PK `ON CONFLICT DO UPDATE`（id 保留）、**LOWER() 归一化查询**、`deleteSwtcNftsByOwner` 的 preserveSwtcEntityAsMeta、collections 增删改 |
| 真实数据回归 | `RealDidDataTests`（fixtures 取两个示例 DID 真实数据：SWTC/ERC-721 VC、CCDAO NFT #8/#4 元数据）/ `NetClientTests`（demo 节点真实 `erc_info`/`eth_call` 响应，覆盖 `fetchMetadataUri`/`resolveEthrTokenUri` 单节点注入路径） | `resolveSwtcAvatar`/`resolveEthrAvatar` 真实 VC 端到端（断言真实 name/图片 CID/issuer/tokenId）、`fetchMetadataFields`/`resolveCredentialImage(s)` 真实元数据、`extractSwtcMetadataUri` 真实 erc_info 形状、eth_call 真实 ABI 解码 + calldata 校验 |
| 头像回退链 | 内存库 + Fake `IEthTokenUriResolver`/`ISwtcTokenUriResolver` | `resolveSwtcAvatar`（nft_meta 命中 / swtc_nfts 行 / erc_info 拉取 / 裸 Nft 四分支）、`resolveEthrAvatar`（resolver URI / nft_meta / evm_nft_items）、`getAvatarCandidates` SWTC/EVM 映射（tokenName = fundCodeName.ifBlank{fundCode}） |
| SwiftDid 集成（阶段二） | `SwiftNft` 注入 `SwiftDid(nft:)` + Fake 桥 | `DidNftResolution` 14 方法 conformance、`generateSwtcNft`/`generateEthrNft` 回退链、`generateProfileVC` 预取 `fetchAndCacheNftMeta`、`getAvatarNftCredentials` 候选、typealias 后 `SwiftDid.NftMetadataFields` 拼写仍可用 |
| 真实网络冒烟（iOS） | 复用 SwiftWebviewBridge 集成基建 | 真实网关拉取、真实 `erc_info` 节点（`https://srje115qd43qw2.swtc.top`）端到端 |

> 单测全部走 Fake `NftHttpClient` + GRDB 内存库（macOS `swift test` 可跑）；真实 URLSession/网络用例放 iOS 模拟器（fastlane `ios_test`）。

## 4. 实施清单

- [ ] 字段对照表校验：`toDidNft()` / `toDidAvatarAsset()` 涉及的 8 字段逐项比对（合并偏离前提，坑 #2）
- [ ] `Package.swift` 注册 `SwiftNft` target（依赖 SwiftDappConnect 取模型 + **GRDB**）
- [ ] `Model/NftModels.swift`：Nft / DidAvatarAsset / NftMetadataFields / CredentialImageRequest / ResolvedCredentialImage / IEthTokenUriResolver / NftMeta + 持仓实体（SwtcNftEntity / EvmNftItemEntity / EvmNftCollectionEntity）+ 单测
- [ ] `Util/NftUrlUtils.swift`：normalizeRemoteAssetUrl(raw, base, gateway:) / isLoadableRemoteAssetUrl / extractMetadataImageUrl / extractSwtcMetadataUri / looksLikeImageAssetUrl + Kotlin 向量 KAT 单测（**含自定义网关贯穿用例**）
- [ ] `Net/SsrfGuard.swift`（getaddrinfo DNS fail-closed；私网/回环/链路本地拒绝；公网 IP 放行；测试旁路开关）+ `Net/NftHttpClient.swift`（10s 超时、**不跟随重定向**、2 MiB 上限）+ `Net/SwtcTokenUriResolver.swift`（erc_info + `getRpcNode` 单节点注入）
- [ ] `Store/NftStore.swift` 协议 + `GRDBNftStore`（四表迁移 / ValueObservation→AsyncStream / LOWER() 查询 / preserveSwtcEntityAsMeta）+ 单测
- [ ] `Cache/NftMetadataImageCache.swift`（actor；**只缓存成功**；per-key Task in-flight 去重；removeAll 取消在途并清空）
- [ ] `SwiftNft.swift` 门面：14 方法完整镜像（`fetchMetadataFields` 非 Optional、`fetchAndCacheNftMeta` 返回 `NftMeta?`、`resolveCredentialImages` 去重、`getAvatarCandidates` 本地持仓映射）
- [ ] **阶段二**：DTO **与 `DidNftResolution` 协议缝一并迁入 SwiftNft**（防依赖环）；SwiftDid 加依赖 + `public typealias`（含协议）；`SwiftNft: DidNftResolution` conformance；`SwiftDid(nft:)` 接入与回退链单测
- [ ] 接入 `Examples/WalletDemo`：`SwiftNft` 作为 DID 头像解析后端 + 持仓同步（若 demo 扩展示）

## 5. 实现偏离记录（实现回写，2026-08-19）

实现已落库（`Sources/SwiftNft/`，commit `1c42534` 之后）。以下为与设计稿/04 章的**实现级补充与偏离**，均已体现在代码注释：

| # | 项 | 说明 |
| --- | --- | --- |
| 23 | `resolveCredentialImages` **有界并发** | Kotlin 顺序执行；实现按 key 去重后分批复用 ≤4 个 Task（`withTaskGroup`），结果按请求序回填——避免大批量瞬间打满连接/线程；同 key 仍只解析一次、nil 也去重 |
| 24 | `fetchJson` 返回 `Data` 且不做 JSON 校验 | 设计稿草案为 `[String: Any]?`；`[String: Any]` 非 Sendable 无法跨协议边界，且客户端校验与门面重复解析——解析收敛到门面一次（`fetchAndCacheNftMeta` 解析失败按「解析失败」记日志），行为与 Kotlin 等价 |
| 25 | **惰性 eth_call** | `resolveEthrAvatar` 的 nft_meta 分支：本地 `tokenUri` 非空时**不再调 resolver**（对 Kotlin 的优化偏离，注释标明；省一次 RPC） |
| 26 | `swtcClient` 构建一次复用 | `SwiftNft.init` 里 `config.resolvedSwtcNftClient()` 建一次存成员，避免每次 `erc_info` 重建 URLSession/delegate |
| 27 | 网关 `precondition` + `normalizedGateway` | `SwiftNftConfig.ipfsGateway` 经 `normalizedGateway` 规范化（trim + 尾部 `/`，空回退默认——修掉「无尾斜杠拼接坏 URL」）；`SwiftNft.init` 对非 http(s) 网关 `precondition` 崩溃（编程错误防护） |
| 28 | 注入 session 的信任边界 | `URLSessionNftHttpClient` 注入自定义 session 时，调用方须保证不跟随重定向（delegate 随 session 固定，无法挂上本模块的 delegate）——注释警告，勿传 `URLSession.shared`；`SwtcTokenUriResolver` 自建普通 session（无 delegate） |
| 29 | 图片缓存简单 LRU | `accessOrder` 数组（命中 `touch` + 插入逐出最旧，`removeAll` 清空），替代「keys.first 任意淘汰」 |
| 30 | `getAvatarCandidates` 移除不可达 catch | 观察流 `AsyncStream`（Failure == Never）不 throw，`firstValue` 非抛——catch 不可达已删 |
| 31 | **EVM eth_call 默认解析器迁入模块** | 按用户要求把 Kotlin app 侧 `com.android.jdid.repository.DefaultEthTokenUriResolver` 移入 SwiftNft（`Net/EthTokenUriResolver.swift`，public，`init(getRpcNode:)` 注入「chainId → RPC URL」函数、模块不内置 RPC URL）；demo 删本地实现改用模块类；03 §2.1「模块不内置 eth_call」随之修订为「接口可注入 + 模块自带默认实现」 |
| 38 | **`rpcUrlsForChain` 重命名为 `getRpcNode`（用户指定）** | `EthTokenUriResolver.init` 参数与属性 `rpcUrlsForChain` → `getRpcNode`（与 `SwtcTokenUriResolver.getRpcNode` 命名统一）；typealias `ChainRpcUrlsProvider` 保留（`@Sendable (Int64) -> String?`）；Kotlin `defaultRpcUrlsForChain` 引用保留 |
| 37 | **resolver 统一走 `NftHttpClient.fetchRpc`（用户指定）** | `NftHttpClient` 协议新增 `fetchRpc(_:body:)`（POST JSON-RPC、**跟随重定向**——与 GET 拉取的 no-redirect 相反，对齐 Kotlin `instanceFollowRedirects = true`）；`URLSessionNftHttpClient` 自持 RPC session（注入 session 时复用）；`EthTokenUriResolver`/`SwtcTokenUriResolver` 删除各自 URLSession，改经 `httpClient.fetchRpc`（`init` 增加 `httpClient: any NftHttpClient = URLSessionNftHttpClient()`）；resolver 的 timeout/maxBodyBytes/session 参数移除，由 httpClient 统一 |
| 36 | **`SwtcTokenUriResolver` 删除 delegate（用户指定）** | 删除 `SwtcURLSessionDelegate`（重定向目标 `SsrfGuard` 守卫 + 可选证书 pinning）与 `certificatePins` 参数：节点可信、直接跟随重定向（对齐 Kotlin `instanceFollowRedirects = true`），与 `EthTokenUriResolver` 同策略；建连前 `SsrfGuard.check` 保留；测试（URLProtocol 桩）不受影响 |
| 35 | **SwiftNftConfig 精简（用户指定）** | `SwiftNftConfig` 由 7 参数精简为 5：删除 `swtcChainNftClient`/`getRpcNode`/`certificatePins`，新增 `swtcTokenUriResolver: (any ISwtcTokenUriResolver)?` 单一注入点（宿主传 `SwtcTokenUriResolver(getRpcNode:)` 或自实现/Fake，nil = SWTC 解析不可用）；门面 `resolvedSwtcNftClient()` 删除，直接持有注入值（`await resolver?.fetchMetadataUri`）；`SwtcTokenUriResolver` 类本身保留 `getRpcNode` 构造（见 #33） |
| 33 | **SWTC 节点也改函数注入（用户指定）** | `SwtcTokenUriResolver`（原 `SwtcNftClient`）删除 `defaultRpcNodes` 成员与 `rpcNodes` 数组，`init(getRpcNode: @escaping SwtcRpcNodeProvider)`（`@Sendable () -> String?`，单 URL）注入节点、模块不内置 `DEFAULT_RPC_NODES`；`SwiftNftConfig.rpcNodes` 同步改为 `getRpcNode: (@Sendable () -> String?)?`（nil = 不配置 SWTC 节点 → 解析返回 nil）；demo 经 `SwtcTokenUriResolver(getRpcNode: { "https://srje115qd43qw2.swtc.top" })` 注入 |
| 34 | **真实数据回归测试（2026-08-20）** | 新增 `RealDidDataTests`（SwiftNft，fixtures 取自两个示例 DID 真实数据）、`NetClientTests`（`fetchMetadataUri`/`resolveEthrTokenUri` 用 demo 节点真实响应 `erc_info`/`eth_call` fixture）、SwiftDid `RealDidDocumentTests`/`DidCredentialHelperTests`（真实文档/VC）、DappConnect `WebAppInterfaceRouteTests`；全量 264 tests，TOTAL 行覆盖率 59.7% → 68.7%（SwiftDid 34% → 50%、WebAppInterface 21% → 51%、EthTokenUriResolver → 99%） |
| 32 | **协议/实现重命名（用户指定）** | 协议 `EthTokenUriResolver` → `IEthTokenUriResolver`（避免与实现类同名）；默认实现 `DefaultEthTokenUriResolver` → `EthTokenUriResolver`；`SwtcChainNftClient` → `SwtcNftClient`（对齐 Kotlin 类名）。`EthTokenUriResolver.init` 由 `rpcUrlsByChain` 字典改为注入 `getRpcNode: ChainRpcUrlsProvider`（`@Sendable (Int64) -> String?`，对齐 Kotlin `defaultRpcUrlsForChain`）——字典/列表改单 URL 函数后「chainId → 节点」映射完全由宿主闭包决定，模块连默认映射也不内置，单节点 eth_call |
