# 01 · Kotlin 版架构

> 本文**已按 `kotlin-toolkits` 源码对齐**（commit `f77b59f`，2026-08-18），源码路径：
> `nft/src/main/java/com/jccdex/toolkits/nft/`。除标注「Swift 增强/偏离」处外，方法签名、模型字段、存储结构、网络行为均与源码一致。

## 1. 模块定位

`:nft` 提供 NFT 元数据能力 + 本地持仓存储：

- **元数据**：元数据 URI 解析与拉取（EVM tokenURI / SWTC `erc_info` 链上解析）、元数据字段提取（`NftMetadataFields`）、凭证/头像图片 URL 解析（VC → metadata → 最终图片 URL 链路）、图片解析结果记忆化缓存、`nft_meta` 持久化缓存（`fetchAndCacheNftMeta`）。
- **本地持仓存储**：Room 四表（`nft_meta` / `swtc_nfts` / `evm_nft_items` / `evm_nft_collections`），宿主把钱包持仓同步进来，`getAvatarCandidates` 从本地表读头像候选。
- 不持有账户/链上状态，是 `:did` 的**编译期依赖**（`DidSdk` 构造时 `nftSdk: NftSdk? = null`，运行时可不接入）。

与 `:dapp-connect` 的 `NftProvider` 是**两个不同关注点**：`NftProvider` 面向 DApp `*_requestNfts` 的持仓枚举（由 App 自实现）；`:nft` 的存储/客户端可供宿主复用，但模块本身只服务 DID/头像等内部解析路径与本地同步。

## 2. 文件与职责（源码实况）

| 文件 | 职责 |
| --- | --- |
| `NftSdk.kt` | 门面：14 个公开方法（§3），薄封装 `NftStore`；`companion create(context, databaseName, ethTokenUriResolver)` / `create(nftDao, ethTokenUriResolver)` |
| `model/NftModels.kt` | `Nft` / `AvatarCandidate` / `NftMetadataFields` / `CredentialImageRequest` / `ResolvedCredentialImage` / `EthTokenUriResolver`；`typealias ChainType`/`WalletAccount` → `:core` |
| `storage/room/NftStore.kt` | 全部实现逻辑：元数据解析链路、`fetchAndCacheNftMeta`、持仓 CRUD/观察、VC JSONPath 解析（Gson）、HttpURLConnection 拉取、缓存键构造 |
| `storage/room/NftDao.kt` | Room DAO：四表 upsert/query/observe/delete |
| `storage/room/NftEntities.kt` | 四个 `@Entity`（§6） |
| `storage/room/NftRoomDatabase.kt` | Room 数据库（`nft_storage.db`，version 1） |
| `remote/NftRemoteAssetResolver.kt` | 纯函数 + 网络：`normalizeRemoteAssetUrl` / `isLoadableRemoteAssetUrl` / `extractMetadataImageUrl` / `resolveRemoteImageUrl` / `fetchMetadataImage` / `SsrfGuard` / `NftMetadataImageCache` / `DEFAULT_IPFS_GATEWAY_BASE_URL` |
| `remote/SwtcChainNftClient.kt` | SWTC 链上 `erc_info` RPC（`DEFAULT_RPC_NODES`，可选证书 pinning） |
| `remote/SwtcNftMetadataParser.kt` | `extractSwtcMetadataUri`（hex InfoType/InfoData 解码）+ `extractMetadataFields` |

> 依赖（`nft/build.gradle.kts`）：`api(project(":core"))`、Gson、coroutines、Room（runtime/ktx/compiler）。`:did` 侧 `implementation(project(":nft"))`。

## 3. NftSdk 全量 API（14 公开方法 = 13 方法名 + `resolveCredentialImage` 重载）

### 3.1 头像解析与候选

| API | 说明 |
| --- | --- |
| `suspend fun getAvatarCandidates(account: WalletAccount): List<AvatarCandidate>` | 从本地持仓表读候选：SWTC 走 `swtc_nfts`（`fundCodeName.ifBlank { fundCode }` 作 tokenName，`contract = issuer`）；EVM 走 `evm_nft_items`（`chainId = account.chain.evmChainId`，hex 化查询；无 evmChainId → 空列表） |
| `suspend fun resolveSwtcAvatar(vc: String): Nft?` | SWTC 头像 VC → Nft（回退链见 §4.2） |
| `suspend fun resolveEthrAvatar(vc: String): Nft?` | EVM 头像 VC → Nft（回退链见 §4.3） |

### 3.2 元数据预取与字段

| API | 说明 |
| --- | --- |
| `suspend fun fetchAndCacheNftMeta(contract, tokenId, tokenUri): NftMetaEntity?` | 拉取 tokenUri 元数据并 **upsert 到 `nft_meta` 表**（含 `fullContent`），返回实体；tokenUri 空白/失败 → null（不 throw） |
| `suspend fun ensureSwtcCredentialMetadata(vc)` | 读 VC `$.credentialSubject.tokenId`/`nftIssuer`，经 `resolveAndCacheSwtcNftMeta` 预取（`resolveSwtcAvatar` 前置） |
| `suspend fun fetchMetadataFields(metadataUri): NftMetadataFields` | 拉取并解析元数据。**非 Optional**：失败返回 `NftMetadataFields(null,null,null)`，不 throw |

### 3.3 凭证/元数据图片解析（8 个方法签名 = 7 方法名 + `resolveCredentialImage` 重载）

| API | 说明 |
| --- | --- |
| `suspend fun resolveCredentialImage(imageUrl: String?, metadataUri: String?): String?` | `resolveRemoteImageUrl`：imageUrl 内联 JSON → 提取；规范化 imageUrl 可加载 → 直出；metadataUri 本身是图片 URL（扩展名白名单/data:）→ 直出；否则拉元数据提图（记忆化缓存） |
| `suspend fun resolveCredentialImage(request: CredentialImageRequest): ResolvedCredentialImage?` | 结构化版，返回 `ResolvedCredentialImage(url, cacheKey)`（cacheKey 构造规则见 §4.4） |
| `suspend fun resolveCredentialImages(requests): List<ResolvedCredentialImage?>` | 批量版：按 `buildCredentialResolutionKey` **去重**（LinkedHashMap `getOrPut`），相同请求只拉一次 |
| `suspend fun fetchResolvedMetadataImage(metadataUrl): String?` | `fetchMetadataImage`：拉元数据 → `extractMetadataImageUrl`（含记忆化缓存） |
| `fun normalizeAssetUrl(rawUrl: String?, baseUrl: String? = null): String?` | **同步**纯函数 = `normalizeRemoteAssetUrl`（规则见 03 §5） |
| `fun extractResolvedMetadataImageUrl(metadataBody, metadataUri): String?` | **同步**纯函数 = `extractMetadataImageUrl`（JSON 容错 + 键顺序 image/image_url/imageUrl + data 解包） |
| `fun isSupportedRemoteAssetUrl(url: String?): Boolean` | **同步**纯函数 = `isLoadableRemoteAssetUrl`（http/https/**data:** 前缀即 true） |
| `fun extractSwtcMetadataUri(tokenInfosPayload: String?): String?` | **同步**纯函数：解析 `erc_info` 的 `TokenInfos` JSON 数组，hex 解码 `InfoType == "tokenUri"` 项，hex 解码 `InfoData` 并规范化 |

> 与 `:did` 透传组对账：Kotlin `DidSdk` 的 NFT 元数据**透传组**为 10 个方法签名 = 9 方法名 + `resolveCredentialImage` 重载——即上表 3.3 全部 8 个 + §3.2 的 `fetchMetadataFields` / `ensureSwtcCredentialMetadata`；`resolveSwtcAvatar` / `resolveEthrAvatar` / `getAvatarCandidates` 在 DidSdk 被包装进 `generateSwtcNft` / `generateEthrNft` / `getAvatarNftCredentials`，不属透传组。本仓库 [Did-Swift 文档](../Did-Swift/02-swift-design.md) 的「10 个元数据方法签名」即指该透传组。

## 4. 解析链路（源码实况）

### 4.1 DID 头像回退链（跨模块，:did 编排）

```text
DidSdk.generateSwtcNft(vc) / generateEthrNft(vc)
  ├─ 1) avatarResolver?.resolveSwtcAvatar / resolveEthrAvatar（宿主注入）
  ├─ 2) nftSdk?.resolveSwtcAvatar / resolveEthrAvatar → toDidNft()   ← 本模块
  └─ 3) buildSwtcNft / buildEthrNft（读 VC 字段的本地兜底）
```

路由：`isSwtcAvatarVc(vc)` 按 `credentialSubject.standard`（`"jingtumnft"` → SWTC，`"erc-721"` → EVM），缺失时按「`nftIssuer` 非空且 `contractAddress` 空 → SWTC」判断。

### 4.2 resolveSwtcAvatar（NftStore 实况）

VC 字段：`$.credentialSubject.tokenId` / `nftIssuer` / `tokenName` + `$.issuanceDate`；tokenId/nftIssuer 空白 → null。回退链：

```text
1) nft_meta 表命中（getNftMeta(nftIssuer, tokenId)）→ buildSwtcNftFromMeta
2) swtc_nfts 表命中（getSwtcNftByIssuerAndTokenId）且 image 或 metadataUri 非空
   → Nft(uri=normalize(metadataUri), image=resolveRemoteImageUrl(image, uri), hasLocal=image!=null)
3) resolveAndCacheSwtcNftMeta(nftIssuer, tokenId)：
   ├─ nft_meta 已有 image → 直接返回
   ├─ 否则 tokenUri = 已有 tokenUri 或 SwtcChainNftClient.fetchMetadataUri(tokenId)（链上 erc_info）
   └─ fetchAndCacheNftMeta(nftIssuer, tokenId, tokenUri)
4) 兜底裸 Nft（name=tokenName、uri="", image=null, hasLocal=false）
```

### 4.3 resolveEthrAvatar（NftStore 实况）

VC 字段：`$.credentialSubject.tokenId` / `contractAddress` / `chainId` + `$.issuanceDate`；tokenId/contractAddress 空白 → null。

```text
resolvedTokenUri = sanitize(normalize(ethTokenUriResolver?.resolveEthrTokenUri(contract, tokenId, chainId)))
1) nft_meta 命中 → Nft(uri=normalize(meta.tokenUri) 或 resolvedTokenUri, image=resolveRemoteImageUrl(meta.image, uri), hasLocal=true)
2) evm_nft_items 命中（getEvmNftItemByContractAndTokenId("0x"+chainIdHex, contract, tokenId)）
   → uri = resolvedTokenUri 或 normalize(evmItem.metadata)，image = resolveRemoteImageUrl(evmItem.imageUrl, uri)
   hasLocal = evmItem.imageUrl != null
```

> `sanitizeUri`：trim 后空白 → `""`；以 `{`/`[` 开头（像 JSON）→ `""`。

### 4.4 resolveCredentialImage(request) 与缓存键

```text
ResolvedCredentialImage(url, cacheKey)
cacheKey（buildCredentialAssetKey 优先级）：
  resolvedUrl 非空            → "image:<resolvedUrl>"
  否则 contract+tokenId 非空  → "nft:<chainId|unknown>:<contract>.lowercase():<tokenId>"
  否则 metadataUri 非空       → "metadata:<normalize(metadataUri)>"
  否则 imageUrl 非空          → "image:<normalize(imageUrl, metadataUri)>"
  否则                        → "image:<resolvedUrl>"
批量去重键（buildCredentialResolutionKey）= chainId|contract.lowercase()|tokenId|normalize(metadataUri)|normalize(imageUrl, metadataUri)
```

### 4.5 图片解析（resolveRemoteImageUrl，源码实况）

```text
1) imageUrl trim 后像 JSON（{ 或 [ 开头）→ extractMetadataImageUrl 提取内联图片
2) normalize(imageUrl, base=normalize(metadataUri)) → isLoadableRemoteAssetUrl → 直出
3) metadataUri 非空且 looksLikeImageAssetUrl（data: 或路径后缀 .png/.jpg/.jpeg/.webp/.gif/.svg/.avif/.bmp）→ 直出
4) NftMetadataImageCache.getOrFetch(normalizedMetadataUri) { fetchMetadataImage(normalizedMetadataUri) }
   → normalize → isLoadable → 直出
5) 否则 null
```

> **缓存语义（关键）**：`NftMetadataImageCache` 只把**成功（非 null）**结果写进 `resolvedByMetadataUrl`；失败不落缓存，下次调用重新拉取（Kotlin 测试锁定：先 500 后 200 时第一次返回 null、第二次成功且请求数 = 2）。

## 5. 模型（源码实况）

| 模型 | 字段 | 说明 |
| --- | --- | --- |
| `Nft` | `contract` / `tokenId` / `name` / `uri` / `issuanceDate` / `image?` / `hasLocal` / `chainId: Long?` | 字段名 `contract` 而非 `contractAddress` |
| `AvatarCandidate` | `image?` / `name` / `contract?` / `tokenId` / `issuer?` / `tokenName?` / `chainId?` / `isSwtc` | 本地持仓行 → 头像候选 |
| `NftMetadataFields` | `image?` / `name?` / `description?` | **仅 3 字段** |
| `CredentialImageRequest` | `imageUrl?` / `metadataUri?` / `chainId: Long? = null` / `contractAddress: String? = null` / `tokenId: String? = null` | |
| `ResolvedCredentialImage` | `url: String`（非空）/ `cacheKey: String` | 供宿主缓存图片 |
| `EthTokenUriResolver` | `suspend fun resolveEthrTokenUri(contract, tokenId, chainId): String?` | 接口（RPC 由宿主实现；模块不内置 eth_call） |
| `WalletAccount` / `ChainType` | 见 `:core` | `typealias` 到 core；`ChainType.evmChainId` 用于 EVM 链 hex |

> `:did` 侧另有 `DidAvatarAsset`（port）与展示模型 `Nft`：字段与 `AvatarCandidate`/`:nft` 的 `Nft` **完全一致**，`toDidAvatarAsset()` / `toDidNft()` 为逐字段拷贝（见 02 §2 的 Swift 合并决策）。

## 6. 存储（Room 四表，源码实况）

| 表 | 主键/索引 | 关键字段 |
| --- | --- | --- |
| `nft_meta` | `id` 自增 PK；`(contract, tokenId)` UNIQUE | `contract`/`tokenId`/`name?`/`image?`/`tokenUri?`/`fullContent?`/`updatedAt` |
| `swtc_nfts` | `(ownerAddress, tokenId)` 复合 PK；`ownerAddress` 索引 | `fundCode`/`fundCodeName`/`issuer`/`tokenOwner`/`tokenInfos?`/`metadataUri?`/`image?`/`name?`/`time`/`hash?`/`block`/`inservice`/… |
| `evm_nft_items` | `(chainId, ownerAddress, contractAddress, tokenId)` 复合 PK | `imageUrl?`/`metadata?`（元数据 JSON 字符串）/`title?`/`description?`/`tokenProtocol?`/`updatedAt` |
| `evm_nft_collections` | `(chainId, ownerAddress, contractAddress)` 复合 PK | `name`/`symbol`/`iconUrl?`/`tokenCount`/`priceUsd?`/`website?`/…（约 22 字段） |

`NftDao` 提供：`upsertNftMeta`（REPLACE）、`getNftMeta`、`deleteNftMeta`、`upsertSwtcNfts`、`observeSwtcNfts`、`getSwtcNftByTokenId`、`getSwtcNftByIssuerAndTokenId`、`deleteSwtcNftsByOwner`、`upsertEvmNftItems`、`observeEvmNftItems`、`observeAllEvmNftItems`、`getEvmNftItem`、`getEvmNftItemByContractAndTokenId`、`deleteEvmNftItemsByCollection`、`getItemCount`、`insertCollections`、`getNftCollectionsFlow`、`deleteByChainAndOwner`、`updateTokenCount`。

> `deleteSwtcNftsByOwner` 删除前先 `preserveSwtcEntityAsMeta`（把有 `metadataUri` 的行写入 `nft_meta`，避免头像元数据随持仓删除丢失）。

## 7. 网络与安全（源码实况）

- **拉取**：`HttpURLConnection` GET，`connectTimeout`/`readTimeout` = 10s，`instanceFollowRedirects = false`（**元数据/图片拉取不跟随重定向**）；2xx 且 body 非空才成功。
- **SSRF（`SsrfGuard`）**：protocol ∈ {http, https, ipfs}（java.net.URL 无法解析 `ipfs://` → 按畸形拒绝）；host 非空；`InetAddress.getByName(host)` 解析失败 → **fail-closed 拒绝**；拒绝 loopback / site-local / link-local（127.0.0.1、localhost、10/8、192.168/16、172.16/12、169.254/16…）；**公网 IP 放行**（测试用例：8.8.8.8、1.1.1.1）；`enabled` 标志可关（仅测试用）。
- **SWTC RPC（`SwtcChainNftClient`）**：POST `{"method":"erc_info","params":[{"tokenid": tokenId}]}` 到 `DEFAULT_RPC_NODES = ["https://srje115qd43qw2.swtc.top"]`（首个成功即返回）；15s 超时；`instanceFollowRedirects = true`（可信节点）；可选证书 pinning（`certificatePins`，SHA-256/Base64）；响应解析 `result.TokenInfo.TokenInfos`（JSONArray 或字符串）→ `extractSwtcMetadataUri`。
- **IPFS 网关**：`DEFAULT_IPFS_GATEWAY_BASE_URL = "https://ipfs.jccdex.cn/ipfs/"`（**Kotlin 硬编码**；Swift 侧可注入但默认同值，见 03 §4）。

## 8. 测试基线（源码实况）

| 测试文件 | 覆盖点 |
| --- | --- |
| `remote/NftRemoteAssetResolverTest` | `SsrfGuard` 全边界（loopback/site-local/link-local 拒、公网 IP 放行、file:/javascript:/ftp 拒、`ipfs://` 按畸形拒、未解析域名 fail-closed、`enabled=false` 旁路） |
| `NftSdkTest`（Robolectric + Room 内存库 + MockWebServer） | `normalizeAssetUrl` KAT（`ipfs://bafy123/avatar.png` → `https://ipfs.jccdex.cn/ipfs/bafy123/avatar.png`；相对路径 join）、`extractResolvedMetadataImageUrl`、`isSupportedRemoteAssetUrl`、`resolveEthrAvatar` 用 resolver URI、`fetchAndCacheNftMeta` 落库、`resolveCredentialImage` 三分支 + **瞬时失败重试**、`resolveCredentialImages` 去重（1 次请求）、`extractSwtcMetadataUri` hex 解码、`fetchMetadataFields` 解 `data` 包、`getAvatarCandidates` SWTC/EVM 映射、`resolveSwtcAvatar`/`resolveEthrAvatar` 回退链 |
| `remote/SwtcChainNftClientTest` | `erc_info` 请求构造、`parseErcInfoMetadataUri`、多节点 fallback |

Swift 移植的测试策略见 [04-migration-and-testing.md](04-migration-and-testing.md)。
