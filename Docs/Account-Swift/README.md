# Account · Swift 移植设计稿

本文档是 `kotlin-toolkits` 中 `:account` 模块的 Swift 版本设计。目标是把 Kotlin 版「钱包账户**元数据**的本地持久化与业务编排」（HD 根/子账户、传统账户的增删改查、当前选中账户管理、与 `:vault`/`:wallet` 协作的导入/派生/删除流程）以 Swift/iOS 惯用方式复刻为 **`SwiftAccount`** 模块。

> 状态：设计稿（按 `kotlin-toolkits` `:account` 源码对齐，2026-08）。文中 Swift 代码为设计示例，用于指导实现。Kotlin 源码路径：`account/src/main/java/com/jccdex/toolkits/account/`（`AccountSdk.kt` / `orchestrator/*` / `store/*` / `storage/room/*`）。

## 核心职责（与 Kotlin 对齐）

- **只存账户元数据**（地址、链、名称、HD 路径、公钥等）；**私钥/助记词由 `SwiftVault` 加密存储**——`SwiftAccount` 不接触密钥明文；
- HD 根账户 / 子账户 / 传统账户的增删改查与观察；
- 当前选中账户（`currentAccount`）管理；
- 按链、地址、父账户等维度查询（含 HD 子账户索引推进 `getMaxIndexByChain`）；
- `AccountOrchestrator`：与 `SwiftVault`（密钥落库）、`SwiftWallet`（地址派生）协作的导入 / 派生 / 删除流程。

## 设计原则

1. **存储用 GRDB 替代 Room**：`AccountStore` 协议 + `GRDBAccountStore`（`accounts` / `current_account` 两表），宿主可替换（对齐 Kotlin `IAccountStore` + `RoomAccountStore`）。
2. **Swift 化 API**：`Flow` → `AsyncStream`（GRDB ValueObservation），`suspend` → `async throws`/`async`，`ByteArray` → `Data`。
3. **共享模型复用 SwiftDappConnect**：`WalletAccount` / `ChainType` / `Path` 已存于 SwiftDappConnect（对应 Kotlin `:core`），`SwiftAccount` 直接复用、不重复定义。
4. **派生能力复用 SwiftWallet**：`deriveChild` / `hdWalletFromMnemonic` / `deriveFromPrivateKey` 已实现（桥 JS），`AccountOrchestrator` 依赖它完成地址派生（对齐 Kotlin 依赖 `:wallet` 的 `WalletSdk`）。
5. **密钥安全边界**：编排器只把派生结果/地址交给 `SwiftVault` 落库；密码经调用方 `Data` 传入（Swift `Data` 无 Kotlin `ByteArray.fill(0)` 的原地清零语义——**显式偏离**，见 04 坑 #2）。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-kotlin-architecture.md](01-kotlin-architecture.md) | Kotlin 版模块解析（已对齐源码）：`AccountSdk` 门面、`AccountOrchestrator`、`IAccountStore`/Room 两表、模型与错误、测试基线 |
| [02-swift-design.md](02-swift-design.md) | Swift 版设计：模块布局、GRDB 两表、`AccountStore` 协议、`SwiftAccount` 门面与 `AccountOrchestrator` 代码草案、并发与安全要点 |
| [04-migration-and-testing.md](04-migration-and-testing.md) | Kotlin → Swift 逐项对照、实现坑（Room→GRDB、Flow→AsyncStream、Data 与密码语义、Mutex→actor、Path 双份）、测试策略与实施清单 |

## 快速接入（设计预览）

```swift
import SwiftAccount
import SwiftDappConnect
import SwiftVault
import SwiftWallet

// 存储：GRDB（对应 Kotlin Room ccdao_accounts.db）
let account = try SwiftAccount(store: GRDBAccountStore(database: DatabasePool(path: ".../account.sqlite")))

// 观察（AsyncStream）
for await accounts in account.accounts { /* 全部账户 */ }
for await current in account.currentAccount { /* 当前选中 */ }
for await roots in account.rootHDAccounts { /* HD 根 */ }

// 编排器（依赖 vault + wallet，负责导入/派生/删除）
let vault = VaultRepository.get()
let orchestrator = account.orchestrator(vault: vault, wallet: walletSdk)

// 导入 HD 钱包
let hd = try await walletSdk.hdWalletFromMnemonic(mnemonic: ..., chains: [ChainType.eth.bip44Code])
let result = await orchestrator.importHdWallet(hd, name: "My HD", password: passwordData)
// result: AccountOperationResult<ImportHdWalletResult>

// 派生子账户（Swift 侧派生需显式密码——见 02 §5 / 04 坑 #6）
let derived = await orchestrator.deriveSubAccount(chain: .eth, rootAccountId: "root", password: passwordData)
```

## 模块边界（与其他 Swift 模块的分工）

| 能力 | 归属模块 | 说明 |
| --- | --- | --- |
| 账户元数据持久化 / 当前选中 / 查询观察 | **SwiftAccount**（本设计稿） | 镜像 Kotlin `:account`（`AccountSdk` + `AccountStore`） |
| 私钥/助记词加密存储、密码校验 | SwiftVault | `importMnemonic` / `importPrivateKey` / `removeAddress` / `verifyPassword` / `clearAllData` |
| 助记词→地址派生（BIP44） | SwiftWallet（桥 JS） | `deriveChild` / `hdWalletFromMnemonic` / `deriveFromPrivateKey`（对应 Kotlin `:wallet` 的 `WalletSdk`） |
| 共享模型（`WalletAccount`/`ChainType`/`Path`） | SwiftDappConnect | 对应 Kotlin `:core`；SwiftNft/SwiftDid/SwiftAccount 均复用 |
| HD 钱包创建/签名等钱包层能力 | SwiftWallet | 账户层只消费派生结果，不重复实现 |

## 与 Kotlin 差异一览

| 维度 | Kotlin | Swift |
| --- | --- | --- |
| 存储 | Room（`AccountRoomDatabase`，`ccdao_accounts.db`，两表） | **GRDB**（`GRDBAccountStore`，两表同构） |
| 观察 | `Flow<List<WalletAccount>>` | `AsyncStream`（ValueObservation 驱动） |
| 门面入口 | `AccountSdk.get(context)`（单例） | `SwiftAccount(store:)`（无需 Context，store 注入） |
| 编排器 | `AccountOrchestrator(store, vault)`，vault 自带解锁态 | `AccountOrchestrator(store, vault, wallet)`；派生需显式密码（SwiftVault 公开读取 `getMnemonic` 每次重校验密码，会话态读取未作稳定 API，见 04 坑 #6） |
| 密码语义 | `ByteArray` + 原地清零（H-R5） | `Data`（无原地清零；调用方负责，见 04 坑 #2） |
| 账户 id | Kotlin 编排器用 UUID 默认 id（调用方可控） | Swift 编排器显式稳定 id `"\(address)#\(chain.bip44Code)"`（偏离，见 04 坑 #1） |
| 并发 | `Mutex` + `suspend` | `actor` 互斥门（链式 Task 串行，仅 `deriveSubAccount` 互斥，见 04 坑 #16） |
| Path | `:core` 与 `:wallet` 双份，互转 `toCorePath`/`toWalletPath` | SwiftDappConnect 与 SwiftWallet 各一份，编排器做等价转换 |
