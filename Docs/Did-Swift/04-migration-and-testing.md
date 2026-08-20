# 04 · 迁移与测试

## 1. Kotlin → Swift 逐项对照

| Kotlin | Swift | 说明 |
| --- | --- | --- |
| `DidSdk` | `SwiftDid`（@MainActor 门面） | 同构 |
| `IDidBridge` | `DidBridge` 协议 | 可注入 Fake（对齐 Kotlin Fake 桥） |
| `AndroidDidWebRuntime` | `EngineDidBridge` | 自持 `WebviewBridgeClient` 加载 `did-bridge.html`（独立隐藏 WebView，不复用共享引擎） |
| `IDidResolver.resolve(did)` | `DidResolver.resolve(did)`（协议，默认 = 桥调 `didResolve`；`SwiftDid.resolveDid` 委托之） | 桥透传 `didResolve` |
| `DidCoreService` | `DidCoreService` | 观察/取档/写操作编排 **+ pending 对账状态机**（四张表，见 01 §6） |
| `IDidStore` + Room | `DidStore` 协议 + `GRDBDidStore` | **GRDB 替代 Room**（Swift 生态等价物） |
| `Flow<DidEntity?>` | `AsyncStream<DidEntity?>`（GRDB ValueObservation） | |
| `JSONObject` | `[String: Any]` / Codable | |
| `ChecksumUtils`（EIP-55） | `Util/Keccak256.swift`（**自实现**） | CryptoKit 无 keccak |
| `:nft` 模块（头像 + 元数据） | **预留 `SwiftNft` 模块（后续新增，可选依赖）** + `DidNftResolution` 接入点（含 10 个元数据方法签名） + `DidAvatarResolver` / `DidAvatarCredentialSource` 宿主注入 | 不裁剪 |
| DApp 面 | 实现 `SwiftDappConnect.DidSDK` | 4 个签名方法 |

## 2. 实现注意点 / 坑

1. **存储用 GRDB 替代 Room**：引入第三方依赖 [GRDB.swift](https://github.com/groue/GRDB.swift)（`from: "7.0.0"`，对应 Kotlin 的 `room-runtime`）。`GRDBDidStore` 映射 `DidRoomDatabase` + `DidRoomDao` + `DidRoomEntity` 三层：`did_documents` 表（did 唯一索引）+ `did_pending` 表（pending 对账，见 01 §6）、`DatabaseMigrator` 建表迁移、`ValueObservation.values(in:)` 直接得到 `AsyncStream`。存储直接选 `DatabasePool`（WAL）：观察流与写操作并存，避免从 Queue 事后迁移的成本（见 02 §4）；注意 Record 的 Codable 映射与 Room 的字段命名差异。
2. **did-bridge.js 网关保持硬编码（不注入）**：`EngineDidBridge.start()` 直接用 SwiftWebviewBridge 默认 bundle 加载 `did-bridge.html`（`resolveBridgeURL` 自动落到 `bridge/` 子目录），无临时 bundle / 占位符替换 / `ipfsBaseURL` 配置面（见 03 §3）。迁移时与 Kotlin `:webview-bridge` 的 `did-bridge.js` 做 `diff` 对齐，避免方法集漂移——网关行是两边共有的硬编码，**无差异**（`security-review.md` D5 为已知接受项）。
3. **keccak-256（首选专门轻量依赖，自实现仅兜底）**：CryptoKit 不提供 keccak-256；**优先选专门的轻量 keccak 依赖**（避免为单个算法引入整个 CryptoSwift），如独立 keccak 包（`swift-crypto`/CryptoKit 也不含 keccak-256，勿指望从它取）；若选 CryptoSwift 须注明「仅取 Keccak variant（0x01 padding，非 SHA3-256）」。确需 `Util/Keccak256.swift` 自实现时，必须与 BouncyCastle 做 KAT 全量交叉验证并固定 CI（仅 `""`/`"abc"` 两条标准向量不够）；供 `ChecksumUtils.toChecksumAddress`（EIP-55）与 VCID 生成复用。
4. **Flow → AsyncStream**：`observeDidDocument` 的增量语义由 GRDB `ValueObservation` 原生提供（写后自动重放），不再需要手写快照流。
5. **写操作编排顺序 + pending 对账**：`resolveBaseDoc → didStat(previousCid) → 修改 → publishDid → save` 的顺序与错误回滚语义照搬 Kotlin `DidCoreService`；**同时照搬四张 pending 表的状态机**（`pendingCreateDids`/`pendingUpdateAvatar`/`pendingUpdateNickname`/`pendingDeleteUpdated`，见 01 §6）——否则写后立即观察会把刚写的数据用链上旧数据冲掉。别在桥层偷懒（否则 previousCid 链断裂）。**Swift 增强：pending 表持久化到 GRDB**（可拆四张或合并 `did_pending` 单表 kind 列，表结构见 02 §4），写落库、对账命中后删除，消除「写后重启」窗口。**注意 TTL**：publish 失败会导致 pending 永久滞留，`did_pending` 需带时间戳 + 过期清理（语义见 01 §6：24h 阈值、首次写入为基准不续期、按 kind 确认才清除、过期失效）。
6. **M-15 结构校验**：`signCredential` 校验 `credential` 必须含 `@context|type`、`credentialSubject`、`issuer|issuerObject`（三条，对齐 Kotlin M-15）；不要放大为内容校验（用户确认在宿主 UI）。
7. **avatar/NFT 预留 `SwiftNft`（不裁剪）**：Kotlin 依赖 `:nft` 模块做头像元数据解析；Swift 侧**规划后续新增 `SwiftNft` 模块镜像之**，SwiftDid 以可选依赖接入（`nft:` 参数，对齐 Kotlin `nftSdk: NftSdk? = null`）。回退链保持 Kotlin 语义：宿主 `DidAvatarResolver` → `SwiftNft` → 本地兜底；未接入前相关方法返回 nil，协议缝（`DidNftResolution`）保留。`DidNftResolution` 需预先覆盖 `:nft` 的 10 个元数据方法签名（9 个方法名，`resolveCredentialImage` 两个重载；见 02 §6），否则后续接入会改 SwiftDid 公开 API。
8. **`DidEntity` 主键与时间戳**：`id` 自增主键保留在 GRDB 记录层（`DidRecord`，对齐 Room `@PrimaryKey(autoGenerate)`），`did` 加 UNIQUE 索引，`save` 走 `INSERT … ON CONFLICT(did) DO UPDATE`（upsert-by-did），等价「并发取最新」；对外 `DidEntity` 不暴露 `id`。`updatedAt` 为毫秒时间戳（`Date().timeIntervalSince1970 * 1000`），别用秒。
9. **缺失文档哨兵**：`resolveDid` 必须把 `"{}"`、`"null"` 与空串（trimmed）都判为缺失（对齐 `DidResolveUtils.isMissingDidDocument` + 空串防御），见 03 §2。
10. **`DidSyncService` 一期裁剪**：Kotlin 的批量同步（`DidSyncEntry/Result`、`nickname(doc)` 供其使用）依赖多账户/多链场景——Swift 一期不实现（显式标注，避免把模型一起删掉），二期补 `DidSyncService` 等价物时复用 `DidStore` 与 `DidResolver`。
11. **删除防复活（Kotlin 死代码陷阱）**：Kotlin `resolveAndSaveDid` 里 `pendingDeleteUpdated` 检查位于 `localDoc == null` 的 `store.upsert(旧文档)` 提前 return **之后**，实际不可达——已删除 DID 在 IPFS 延迟窗口内会被链上旧文档复活。Swift 实现必须在「`localDoc == nil && 链上非缺失`」的 upsert **之前**先查 `pendingDeleteUpdated`（链上 `updated == 删除时间戳` → 不复活、清表、返回 nil）；测试补「删除后链上旧文档未传播时不复活」用例。
12. **共享引擎冲突（新增修正）**：`WebviewBridgeEngine.shared` 单例已被 SwiftWallet 的 `wallet-bridge.html` 占用（`WebviewBridgeClient.start()` 对已有 runtime 直接 return），SwiftDid 不得复用；必须自持 `WebviewBridgeClient` 实例加载 `did-bridge.html`（对齐 Kotlin 第二个隐藏 WebView），见 02 §3。
13. **`updated` 用 Date 比较（勿照搬 Kotlin 字符串比较）**：解析 ISO8601（含不定长小数位，开 `.withFractionalSeconds`）后比较 `Date`，测试覆盖精度不一致场景（`…0.12Z` vs `…0.1Z`）。
14. **`didStat` 失败即发布失败（不重试）**：previousCid 取不到时**直接中止发布并上抛**（Kotlin 静默吞错导致 IPFS 链分叉，见 01 §6），不得静默继续。实现不做重试——fail-closed 语义优先，单次失败即中止、由用户重试（与早期「有限重试 1–2 次」草案的差异已回写）。
15. **`resolveAndSaveDid` 返回类型化结果**：定义 `DidResolveOutcome { case missing / error(any Error) / document(String) }` 三态，桥/网络错误不得伪装为「链上缺失」，否则 `resolveOwnerDidDocument` 静默回退本地陈旧缓存、验签/撤销检测失真。**约定：`resolveDid`/`resolveAndSaveDid` 不 throw**——所有失败统一进 `.error`，由调用方 switch 决策（throw 通道留给编程错误，如参数非法）。
16. **`DidStore` 协议必须含 pending CRUD**：`savePending/loadPending/deletePending/deleteExpiredPending`（见 02 §4），否则对账状态机无法注入 Fake 测试、宿主也无法替换存储。
17. **`DidNftResolution` 补 `fetchAndCacheNftMeta`**：Kotlin `NftSdk` 共 14 个公开方法，协议须完整镜像（含 `generateProfileVC` 依赖的元数据预取缓存）；`fetchMetadataFields` 返回非 Optional（对齐 Kotlin）。
18. **`service`/`services` 键名归一化**：写 `service` 前删除旧 `services` 键（反之亦然），避免同一文档双键（Kotlin 现状缺陷）。
19. **`signCredential` 补 keyDoc 校验**：M-15 三条之外校验 `keyDoc.did`/`keyDoc.id`（JS 强依赖，见 03 §2），先于桥报错返回 `SwiftDidError.invalidCredential`。
20. **keccak-256 首选专门轻量依赖**：见本条坑 #3；自实现必须 KAT 全量交叉验证。
21. **`verifyCredential` 保留 `errorKind`/`error`**：JS 返回含失败原因，Kotlin 丢弃了；Swift 模型带上，供宿主展示验签失败原因。
22. **（已废弃）网关注入临时 bundle 缓存**：曾规划 `makeTempBundle` 按资产集 hash 缓存替换后的 did-bridge.js——**网关现保持硬编码（03 §3），该机制已删除**（`DidBridgeAssets` 不再存在）；若日后恢复网关注入，再按「整个资产集内容 hash」缓存目录，避免仅 hash 单个文件在其余资产升级时命中旧缓存。

## 3. 测试策略

| 层级 | 方式 | 覆盖 |
| --- | --- | --- |
| 模型/工具单测 | `DidModelsTest` 等价 + `Keccak256Test` | Codable 往返、keccak-256 标准测试向量、VCID 生成规则（EVM/SWTC 两种格式）、Profile 解析 |
| 桥单测 | `FakeDidBridge`（对齐 Kotlin `installBridgeForTest`） | 参数构造、返回解析、`signCredential` 结构校验分支（缺 @context/credentialSubject/issuer、**缺 keyDoc.did/id**） |
| 服务层 | `GRDBDidStore`（内存 `DatabasePool`）+ Fake 桥 + Fake resolver | resolveBaseDoc 回退链（currentDoc → 链上 → 本地）、previousCid 填充、publish 成功/失败落库、**pending 对账（create/avatar/nickname/delete 命中与清理路径、写后重启恢复、TTL 过期失效）、`updated` 精度不一致比较、didStat 失败拒绝发布、resolve 错误不伪装缺失** |
| 存储 | `GRDBDidStore` | 建表迁移（含 did_pending）、observe/get/save/delete、ValueObservation 写后重放、upsert-by-did、**pending CRUD 协议 + TTL 清理** |
| 真实桥冒烟（iOS） | 复用 SwiftWebviewBridge 集成基建 | `didResolve` / `generatePublicKeyBase58` 端到端（含 publish 路径；网关为 did-bridge.js 硬编码） |
| DidSDK 对接 | 中间件测试注入 `SwiftDid` | `did_*` / `ipfs_*` 方法转发 |
| 生命周期 | `SwiftDid` 自持 client 与 SwiftWallet 共享引擎并存 | 两个隐藏 WebView 互不干扰、`destroy()` 只销毁自己的 runtime、启动顺序无关 |

> 单测全部走 Fake 桥 + GRDB 内存库（macOS `swift test` 可跑）；真实 WebView 用例放 iOS 模拟器（fastlane `ios_test`）。

## 4. 实施清单

- [ ] 与 Kotlin `:webview-bridge` 对齐 `did-bridge.html` / `did-bridge.js`（`diff` 校验；网关保持硬编码，D5 为已知接受项，无占位差异）
- [ ] `Package.swift` 注册 `SwiftDid` target（依赖 SwiftWebviewBridge + SwiftDappConnect + **GRDB**）
- [ ] keccak-256：首选专门轻量依赖；确需 `Util/Keccak256.swift` 自实现则 KAT 交叉验证（EIP-55 / VCID 前置）
- [ ] `DidModels.swift` / `CredentialModels.swift`：模型镜像 + 单测
- [ ] `DidStore` 协议（**含 pending CRUD**）+ `GRDBDidStore`（建表迁移 / ValueObservation / CRUD / TTL 清理）+ 单测
- [ ] `DidCoreService`：观察/取档/写操作编排（resolveBaseDoc / previousCid / publish 落库；**updated 按 Date 比较、didStat 失败即中止、类型化 resolve 结果**）
- [ ] `SwiftDid` 门面：生命周期（**自持 `WebviewBridgeClient`**，不复用共享引擎）+ 全部 API + `DidSDK` conformance + `DidNftResolution` 接入点（**完整镜像 NftSdk 14 方法**）
- [ ] 单测（FakeDidBridge + GRDB 内存库，含 pending 对账与重启恢复、updated 精度、didStat 失败、keyDoc 缺失）与 iOS 冒烟测试
- [ ] 接入 `Examples/WalletDemo`：用 `SwiftDid` 替换 `DidSDK` 桩（若 demo 扩展示）
- [ ] **后续：新增 `Sources/SwiftNft/`（镜像 Kotlin `:nft`），SwiftDid 传入 `nft:` 接入头像解析**
