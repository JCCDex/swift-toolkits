# 01 · Kotlin 版架构

## 1. 模块定位

`:did` 提供 DID（去中心化标识）能力：DID 文档的解析/发布/本地缓存、Profile 与头像、NFT 凭证（VC）签发/验证/授权绑定（VCID）、IPFS 签名，以及 DApp 侧 `did_*` / `ipfs_*` 方法。它依赖隐藏 WebView 的 `did-bridge.html`（`:webview-bridge`）执行链上/加密操作，本地文档用 Room 缓存。

## 2. 文件与职责

| 文件 | 职责 |
| --- | --- |
| `sdk/DidSdk.kt` | 门面：全部对外 API（见 §3） |
| `sdk/AndroidDidWebRuntime.kt` | `IDidBridge` + `IDidResolver` 实现：隐藏 WebView 加载 `did-bridge.html` |
| `port/DidSdkPorts.kt` | `IDidBridge`（call/callAs）、`IDidAvatarResolver`、`IDidAvatarCredentialSource`、`DidAvatarAsset` |
| `service/DidCoreService.kt` | 观察/取档/落库编排（store + resolver） |
| `service/IDidResolver.kt` | `resolve(did)` 链上解析 |
| `service/DidSyncService.kt` | 多 DID 批量同步（**Swift 一期裁剪、二期补**，见 04 章坑 #10） |
| `storage/room/*` | Room 数据库 + DAO + Entity |
| `store/IDidStore.kt` | `observeAll` / `observe(did)` / 读写 |
| `util/ChecksumUtils.kt` | EIP-55 checksum |
| `util/DidCredentialHelper.kt` | VC id 生成、subject 构建、类型/上下文路由、校验 |
| `util/DidResolveUtils.kt` | 缺失文档判定等 |

## 3. DidSdk 全量 API

### 3.1 DID / Profile

| API | 说明 |
| --- | --- |
| `toDid(wallet)` | 地址 → DID（`did:ethr:0xChecksum` / `did:swtc:...`）；依赖 `WalletAccount`/`ChainType`（core 模型，Swift 侧已存于 SwiftDappConnect）；不支持的链 `error(...)` 抛异常 |
| `formatAddress(address)` | 前 4 位 + `***` + 后 4 位（如 `0x12***abcd`，`length<=8` 原样返回） |
| `nickname(doc)` | 取昵称（`getProfile(doc)?.nickname`，`DidSyncService` 依赖） |
| `observeDidDocument(did): Flow` / `observeAllDidDocuments(): Flow` | 本地文档观察 |
| `getDidDocument(did)` | 本地取档 |
| `resolveDid(did)` | 链上解析 + 落库 + 对账（委托 `DidCoreService.resolveAndSaveDid`；内部经 `DidResolver` 纯链上解析） |
| `getProfile(doc)` | 解析 `{nickname, preferredAvatar}` |
| `generateDid(did)` | 文档 → `Did` 展示模型（`created/updated` 经 `formatUtc` 转 `Asia/Shanghai` 的 `yyyy-MM-dd HH:mm:ss`） |
| `generateProfileVC(did)` | Profile + 头像 NFT 展示模型 |
| `generateSwtcNft(vc)` / `generateEthrNft(vc)` | 按 VC 内容路由解析头像（`isSwtcAvatarVc` 按 `credentialSubject.standard`/`nftIssuer` 路由） |
| `getAvatarNftCredentials(account)` | 头像候选（`avatarCredentialSource` → `nftSdk.getAvatarCandidates`，依赖 `:nft`） |
| `resolveCredentialImage(s)` / `fetchMetadataFields` / `extractSwtcMetadataUri` 等 **10 个方法签名（9 个方法名，`resolveCredentialImage` 两个重载）** | NFT 元数据透传（依赖 `:nft`，见 SwiftNft 预留；注意 `NftSdk` 另有 `fetchAndCacheNftMeta`，共 14 个公开方法，Swift `DidNftResolution` 须完整镜像，见 02 §6） |

### 3.2 凭证（VC）管理

| API | 说明 |
| --- | --- |
| `readCredentials(doc)` / `addCredentialToDid(...)` / `deleteCredentialFromDid(...)` | 增删凭证并发布 |
| `verifyCredential(credentialJson)` | 验签；先查 `expirationDate`（过期→false，空输入抛 `IllegalArgumentException`），UsageAuthorization 再查链上是否被撤销/变更 |
| `checkGranteeCredentialUpdate(credentialJson)` | 被授权 VC 变更检测 |
| `updateDidAvatar(...)` / `updatePreferredAvatar(...)` | 头像（新签 VC / 绑定已有 VCID） |
| `queryAndValidateVcid(vcid)` / `bindVcidToDid(...)` | VCID 查询校验与合并发布 |

### 3.3 签名（DApp 面，对应 `SwiftDappConnect.DidSDK`）

| API | 桥方法 | 说明 |
| --- | --- | --- |
| `didGenerateBase58PublicKey(privateKey)` | `generatePublicKeyBase58` | base58 公钥 + 验证方法类型 |
| `signCredentialForDApp(privateKey, payload)` | `signCredential` | 钱包侧 issueVC 签名；**只校验结构（M-15）**，用户确认由宿主 |
| `ipfsGetPublicKey(privateKey)` | `ipfsGetPublicKey` | 压缩 secp256k1 公钥（hex） |
| `ipfsPersonalSign(privateKey, data: IntArray)` | `ipfsPersonalSign` | IPFS 前缀消息 SHA-256 + secp256k1 签名（DER hex） |

### 3.4 写操作入口与内部编排

写操作入口（`DidSdk` 公开 API，Swift `SwiftDid` 需逐一镜像）：

| API | 说明 | 落库 |
| --- | --- | --- |
| `uploadInitialDidDoc(privateKey, did, nickname)` | **初始 DID 创建/发布**（generatePublicKeyBase58 → didStat → generateDidDoc → publishDid） | `saveNewCreatedDid` |
| `updateDidNickname(privateKey, did, nickname, currentDoc)` | 改昵称 | `saveNewNicknameDid` |
| `publishDidDelete(privateKey, did)` | 删 DID（发空文档 `{}` 后删本地） | `deleteDidDocument` |
| `updateDidAvatar(...)` / `updatePreferredAvatar(...)` | 头像（新签 VC / 绑定已有 VCID） | `saveNewAvatarDid` |
| `addCredentialToDid(...)` / `deleteCredentialFromDid(...)` / `bindVcidToDid(...)` | 凭证增删/绑定 | `saveDidDocument` |

凭证/头像/昵称/绑定等修改类写操作共用编排链：

```text
resolveBaseDoc(did, currentDoc)  →  didStat（previousCid）→ 修改文档（updated/credentials/service）
→  publishDid(did, privateKey, doc)  →  core.saveDidDocument(did, doc)
```

`uploadInitialDidDoc` 走**另一条**初始创建链（不 `resolveBaseDoc`，直接生成新文档）；`publishDidDelete` 发布空文档后删除本地记录。初始文档必须经 `ensureCredentialsArrayInDidDocument` 补 `credentials: []`（Kotlin 有 internal 归一化，Swift 同样保留；注：当前 `did-bridge.js` 的 `generateDidDoc` 末尾已自带 `credentials = []` 兜底，Kotlin 侧归一化是冗余防御，Swift 保留即可、不必依赖 JS 行为）。

## 4. 模型（数据类）

| 组 | 模型 |
| --- | --- |
| 链 | `GenerateBase58PKResult{type, publicKeyBase58}`、`PublishDidResult{code, message}`、`DidStatResult{cid?}` |
| 展示 | `Did{id, created, updated, verificationMethods[]}`、`VerificationMethod`、`Profile{nickname, preferredAvatar}`、`Nft`、`ProfileVC` |
| 存储 | `DidEntity{id, did, doc, updatedAt}`、`DidSyncEntry/Result` |
| 凭证 | `UnifiedNftCredentialData`、`CredentialAuthorizationType{SELF, OTHERS}`、`UsageRights`、`NftCredentialRestrictions`、`CredentialVerificationResult{verified, results?}`、`GranteeCredentialUpdateResult{isUpdate, credential?, fetchFailed}`、`QueryVcidResult{isValid, credential?}`、`DidWriteResult{success, didDocument?}`、`DidAvatarCredential` |

> 依赖外部模型：`WalletAccount`/`ChainType`（core，Swift 已存于 SwiftDappConnect）；`DidAvatarAsset`（port）；NFT 元数据模型 `NftMetadataFields` / `CredentialImageRequest` / `ResolvedCredentialImage` / `AvatarCandidate` / `EthTokenUriResolver`（`:nft`，Swift 侧预留 `SwiftNft`）。

## 5. 桥方法清单（did-bridge.js）

`publishDid` / `didResolve` / `didStat` / `generatePublicKeyBase58` / `signCredential` / `ipfsGetPublicKey` / `ipfsPersonalSign` / `generateVC` / `verifyCredential` / `generateDidDoc`

## 6. DidCoreService 对账（IPFS 最终一致性 · 关键）

IPFS 发布有延迟（本地先写、链上后可见），`DidCoreService` 用四张 pending 表做对账，避免链上旧数据覆盖本地刚写的新数据：

| pending 表 | 触发 | 作用 |
| --- | --- | --- |
| `pendingCreateDids` | `saveNewCreatedDid` | 初始 DID 刚发布、链上尚未可见时，`handleMissingChainDocument` 不删本地 |
| `pendingUpdateAvatar` | `saveNewAvatarDid`（记 preferredAvatar） | 链上头像尚未刷新时，`resolveAndSaveDid` 不回退本地 |
| `pendingUpdateNickname` | `saveNewNicknameDid`（记 nickname） | 同上（昵称） |
| `pendingDeleteUpdated` | `deleteDidDocument`（记 updated 时间戳） | **防 IPFS 延迟窗口内链上旧文档复活本地删除**（链上仍服务旧文档且 `updated == 删除时间戳` 时，保留本地删除状态并清表）；tombstone `"{}"` 会被缺失哨兵拦截、不走到此分支。**⚠️ Kotlin 源码陷阱**：该检查在 `localDoc == null` 的 upsert 分支（`store.upsert(旧文档)` 提前 return）**之后**，实际不可达（死代码）——Swift 实现必须把 `pendingDeleteUpdated` 检查**前置**到「`localDoc == nil && 链上非缺失` 的 upsert 之前」，否则已删除 DID 会被链上旧文档复活 |

`resolveAndSaveDid` 核心：比较本地 `updated` vs 链上 `updated` 时间戳，仅当链上更新才 upsert；链上缺档时走 `handleMissingChainDocument`（pendingCreate 命中则保留本地，否则 `store.delete`）。Swift `DidCoreService` 必须照搬这四张表的状态机，否则「写后立即观察」会把刚写的数据冲掉。

> **Swift 必须一并修正的 Kotlin 隐性缺陷（与死代码陷阱同源，勿照搬）**：
>
> 1. **`updated` 字符串比较**：`DidCoreService` 用 `chainUpdated > localUpdated` 做字典序比较（`DidCoreService.kt:64`），而 `updated` 是 `Instant.now().toString()`，小数位不定长（0/3/6/9 位）。精度不齐时字典序判错（如 `…0.12Z` < `…0.1Z`，但 120ms 实际晚于 100ms）。Swift 必须解析为 ISO8601 `Date`（开 `.withFractionalSeconds`）再比较，测试覆盖精度不一致场景。
> 2. **`didStat` 失败静默吞掉**：`uploadInitialDidDoc` 与 `readDidStatCid` 对 `didStat` 异常统一返回 `""`，发布出的新文档缺 `previousCid`，IPFS 历史链分叉。Swift 应将 `didStat` 失败视为发布失败（重试/中止），不得静默继续。
> 3. **`resolveAndSaveDid` catch-all 吞异常**：桥/网络异常与「链上缺失」都返回 nil，`resolveOwnerDidDocument` 会静默回退本地缓存，验签/撤销检测可能展示陈旧数据。Swift 应返回带状态的结果（missing/error/document）或把错误上抛给调用方。
> 4. **`service`/`services` 双键漂移**：初始文档经 JS `generateDidDoc` 产出，键可能是 `services`；更新类操作一律 `json.put("service", ...)`（`DidSdk.kt:493/569/858/1077`）且不删旧键，导致同一文档同时含两个键。Swift 写入前必须做键名归一化。
> 5. **发布成功但本地落库失败**：`publishDid` 返回 code 0 后 `core.saveXxx` 抛错会被外层 catch 吞掉并返回 false，调用方误以为发布失败，而链上已更新。Swift 应区分「发布失败」与「本地持久化失败」，后者至少告警并重试落库。
>
> **Swift 增强（对 Kotlin 的显式偏离）**：Kotlin 用进程内 `ConcurrentHashMap`（App 重启即丢失，重启后链上旧数据会覆盖本地新写入）。Swift 侧**把四张 pending 表持久化到 GRDB**（与 `did_documents` 同库同迁移；合并为 `did_pending` 单表 + `kind` 列，表结构见 02 §4），写落库、对账命中后删除——**消除重启窗口**，行为严格优于 Kotlin。
>
> **注意 TTL/清理（语义细化）**：若 publish 实际失败（链上永远不反映），pending 会永久滞留、长期掩盖链上真实状态。持久化后必须带 `updatedAt` 时间戳 + 过期清理，否则从「内存态重启丢失」退化成「永久保护脏数据」的新 bug。具体语义：
>
> 1. **过期阈值**：默认 **24h**（可配置，`did_pending` 的 `updatedAt` 为写入时间）；
> 2. **TTL 以首次写入为基准**：对账命中只验证、**不刷新** `updatedAt`——否则「链上永不反映」的 pending 会被不断续期、清理形同虚设；
> 3. **正常清除条件（按 kind，不可用统一的「链上 `updated` 变新」判定）**：`avatar`→链上 `preferredAvatar == pending 值`；`nickname`→链上 `nickname == pending 值`；`delete`→链上 `updated == 删除时间戳`（旧文档仍服务）**或链上缺失（tombstone 已传播）**，两者皆视为删除已确认（旧文档路径必须**先于** `localDoc == nil` 的 upsert 分支执行，见本表 `pendingDeleteUpdated` 行的 Kotlin 陷阱）；`create`→链上**返回非缺失文档**即清。**实现位置**：create 的清除放在 `resolveAndSaveDid` 判定「链上非缺失」之后（与后续是否 upsert、`updated` 比较无关），`handleMissingChainDocument` 对 create 只保留、不清（避免沿用 Kotlin「首次缺失即清」的老路）；delete 的「链上缺失」清除与 `handleMissingChainDocument` 的 `store.delete` 同处。用统一 `updated` 判定会清错 create/avatar/nickname，且「后续演进」会误清尚未确认的 pending。
> 4. **过期失效行为**：删除过期 pending → 下次 `resolveAndSaveDid` 按链上/缺失正常处理（不再保护本地），如实反映链上真实状态。
>
> **清理触发点**：不启动定时器——`resolveAndSaveDid` 内按 `did` 顺带清理（`DELETE FROM did_pending WHERE did = ? AND updatedAt < now - TTL`）+ 迁移后启动时一次全表清理即可。

## 7. 测试基线

- 模型/工具单测：`DidModelsTest`、`ChecksumUtilsTest`、`DidCredentialHelperTest`、`DidResolveUtilsTest`
- 服务层：`DidCoreServiceTest`、`DidSyncServiceTest`（Fake store/resolver）
- SDK：`DidSdkTest`（Fake `IDidBridge` 注入）、`DidSdkIntegrationTest`（真实桥冒烟）
- 存储：`DidDaoTest`、`RoomDidStoreTest` 等（Room 内存库）
