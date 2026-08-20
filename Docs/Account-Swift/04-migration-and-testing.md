# 04 · 迁移与测试

## 1. Kotlin → Swift 逐项对照

| 维度 | Kotlin | Swift |
| --- | --- | --- |
| 门面 | `AccountSdk.get(context)`（单例）/ `create(context)` / `createForTest(store)` | `SwiftAccount(store:)`（无需 Context；store 注入，测试注入 Fake/MemoryStore） |
| 存储 | `IAccountStore` + `RoomAccountStore`（Room，`ccdao_accounts.db`） | `AccountStore` 协议 + `GRDBAccountStore`（两表同构；`addAccount`/`addAccounts` 冲突即抛、仅 `current_account` 单行 upsert，见坑 #14） |
| chain 还原 | `ChainType.fromBip44Code(chain)` | SwiftDappConnect 仅有 `bip44Code`（单向）——**需补充 `fromBip44Code(_:) -> ChainType?`**（或 SwiftAccount 内部 `allCases.first{ $0.bip44Code == code }`），见坑 #12 |
| 观察 | `Flow<List<WalletAccount>>` / `Flow<WalletAccount?>` | `AsyncStream<[WalletAccount]>` / `AsyncStream<WalletAccount?>`（ValueObservation） |
| 编排 | `AccountManager(store, vault)` | `AccountManager(store, vault, wallet)`（Swift 显式注入 wallet 派生能力） |
| 错误 | `AccountOperationResult<T>` 密封类 + `AccountOperationError` | `AccountOperationResult<Value>` enum + `AccountOperationError` enum |
| 密码 | `ByteArray`（H-R5 原地清零） | `Data`（无原地清零，显式偏离） |
| 解锁态 | `vault.getMnemonicUnlocked(address)`（会话态读取） | SwiftVault 公开读取 `getMnemonic` 每次重校验密码 → `deriveSubAccount` 显式传 `password`（偏离，见坑 #6） |
| 账户 id | Kotlin 编排器用 UUID 默认 id（调用方可控） | Swift 编排器同样用 UUID 默认 id（判重依赖 address 预检，见坑 #1） |
| 互斥 | `Mutex` | actor 互斥门（仅 deriveSubAccount，见坑 #16） |
| Path | `:core.Path` ↔ `:wallet.Path` 互转（双份） | **统一到 SwiftCore.Path**（含 derivationPath/Codable；SwiftDappConnect 与 SwiftWallet 原双份已合并，无需互转） |

## 2. 实现坑

1. **`WalletAccount.id` 用默认 UUID（对齐 Kotlin）**：Swift `WalletAccount.init` 默认 `id = UUID().uuidString`，编排器**不覆盖**（与 Kotlin 一致：id 是调用方可控的业务键）。**判重不依赖 id**：`importSingleAccount`/`importSubAccount` 入口先 `findNonRootAccount(address, chain)` 按地址判重、`importHdWallet` 根账户按 `findRootAccountByAddress` 判重、子账户按地址跳过已存在——重复导入返回 `addressAlreadyExists`/`accountAlreadyExists`，不会落库，`removeAccount` 的 vault 清理用 `getSameAccountsCount(address)`（与 id 无关）。宿主直接调门面 `addAccount` 时自行保证幂等（store 层按 id 唯一约束冲突即抛，见坑 #14）。
2. **`ByteArray` 清零语义缺失**：Kotlin `importHdWallet` 的「password 与 clearExistingPassword 必须 distinct（H-R5：verify/clear 会原地 wipe）」在 Swift `Data` 上不存在——Swift 不复制/不清零密码缓冲，调用方自行保证两个参数不是同一份可变缓冲。文档注明，勿试图用 `Data` 模拟原地清零。
3. **GRDB 建索引**：`TableDefinition.index(_:)` 在 GRDB 7 不可用（Nft-Swift 04 坑 #3 同款）；用迁移后 `try db.create(index:on:columns:)`。
4. **`current_account` 单行语义**：`setCurrentAccount` 用 `INSERT ... ON CONFLICT(id) DO UPDATE`（id 固定 1；单行下与 REPLACE 等价，沿用 GRDB upsert 惯例）；`removeAccount` 后若删的是 current → **删除该行**（对齐 Kotlin `clearIfCurrent`；`accountId` 列 NOT NULL，**不能置空**，见 02 §2），观察流随之推 nil——补测试「删除当前账户 → current 流推 nil」；`clearAllAccounts` 会**一并清空 `current_account`**（对齐 Kotlin `deleteAll`）。
5. **AsyncStream 观察初始化**：`observeCurrentAccount` 首帧应推送当前值（GRDB ValueObservation 首次查询即推送），宿主 `for await` 即可拿到初始态；空库推 nil。
6. **`getMnemonicUnlocked` 对应物可用性差异（Swift 偏离）**：Kotlin 派生走 vault 会话态 `getMnemonicUnlocked(address)`；SwiftVault **有**解锁态（公开 `isUnlocked`/`unlock`/`lock`；会话密钥 `sessionKey` 为 private），但公开读取 `getMnemonic(address:password:)` 每次经 `ensureUnlocked` 重校验密码，会话态读取仅以 `getMnemonicInternal(address)`（`public` 但名字带 "Internal"、未作稳定 API）暴露。因此 `deriveSubAccount` 增加 `password` 参数、走 `getMnemonic(address:password:)`（设计决策，见 02 §5）；若日后把 `getMnemonicInternal` 提升为稳定公开 API，可回退 Kotlin 签名。**⚠️ 自动解锁副作用**：`getMnemonic`/`removeAddress` 都走 `ensureUnlocked`，vault 锁定时会用传入密码解锁并建立会话——`deriveSubAccount`/`removeAccount` 调用后 vault 处于解锁态（Kotlin 对应路径不建立会话、`deriveSubAccount` 在锁定态直接 `Failure("Vault is locked")`），属显式偏离，宿主按需 `lock()`。
7. **`importSubAccount` 的 keypair 语义**：Kotlin `DerivedSubAccount` 只带 publicKey；`importSubAccount` 复用 `importSingleAccount` 并构造 `Keypair(privateKey = "", publicKey = derived.publicKey)`，`persistVaultMaterial` 走 `else → importPrivateKey(address, "")`，但地址已在 `deriveSubAccount` 阶段 import 过、`importPrivateKey` 的 `addressInKeys` 判重使其 no-op（SwiftVault `importPrivateKey` 同样有 `addressInKeys` 短路）。Swift 实现**推荐显式跳过 `persistVaultMaterial`**（不碰私钥，语义直白）；备选照 Kotlin 传空私钥靠 `addressInKeys` 判重短路——**二者行为一致，勿重复导入真实私钥**。
8. **SwiftWallet 桥启动前置**：Kotlin 使用编排器前须 `WalletSdk.initialize(context); start()`（隐藏 WebView runtime）；Swift 对应 SwiftWallet 桥启动（@MainActor）；编排器方法里派生前确认桥已就绪（或由宿主在构造前启动），见 02 §4。
9. **异常 → 错误枚举**：Kotlin `runOperation` catch 所有异常 → `Failure(cause)`；Swift `AccountOperationError.failure(String)` 只带 message（不跨模块暴露 Error 装箱）；`vault.verifyPassword` 抛错（SwiftVault 锁态等）按 `wrongPassword` 或 `failure` 映射——实现时按 SwiftVault 实际错误枚举对齐。
10. **判重语义**：`findNonRootAccount(address, chain)` 判重（Kotlin 注：不判根）；`importHdWallet` 用 `findRootAccountByAddress` 判重；`getSameAccountsCount` 跨链同地址计数（同地址不同链算多次）。
11. **address 查询大小写归一化**：Kotlin DAO 全部 `COLLATE NOCASE`（`findByAddress`×2 / `findRootAccountByAddress` / `findNonRootAccount` / `getSameAccountsCount` / `updateNameByAddress`）；GRDB 用 `LOWER(address) = LOWER(?)` 归一化（与 SwiftNft/SwiftDid 的 LOWER() 惯例一致），否则 EVM 校验和地址大小写变体被判为不同账户。
12. **`ChainType.fromBip44Code` 缺失**：GRDB 读出 `chain`(Int64) 还原 ChainType 需反向映射；SwiftDappConnect 未提供——**在 SwiftDappConnect 补 `static func fromBip44Code(_:) -> ChainType?`**（对齐 Kotlin core），或 SwiftAccount 内部扩展 `ChainType.allCases.first { $0.bip44Code == code }`（未知 code → 按 Kotlin `AccountEntity.toWalletAccount` 回退 `.eth`）。
13. **`ChainType.label` 缺失**：Kotlin `importHdWallet` 子账户命名为 `"${chainType.label}-HD"`（"Ethereum-HD" / "SWTC-HD"…）；SwiftDappConnect `ChainType` 无 `label`（仅 bip44Code/evmChainId/isEvm/isSwtc）——**在 SwiftDappConnect 补 `label: String`**（对齐 Kotlin `ChainType.label`），否则子账户命名只能回退 `rawValue`（"eth-HD"），与 Kotlin 风格不一致。
14. **`addAccount` 冲突策略**：Kotlin Room `@Insert` 默认 ABORT——重复 `id` 抛 `SQLiteConstraintException`；Swift `GRDBAccountStore.addAccount` 用普通 `INSERT`（冲突抛错）对齐该语义，`addAccounts` 同理（批量由编排器判重后插入）；勿默认 `ON CONFLICT DO UPDATE`（会静默覆盖重复 id，掩盖编程错误）。`current_account` 除外（固定单行 upsert）。
15. **`getMaxIndexByChain` 空表返回 -1（非 0）**：Kotlin `RoomAccountStore.getMaxIndexByChain = dao.getMaxIndexByChain(...) ?: -1`（`MAX(pathIndex)` 空表为 NULL）；`deriveSubAccount` 依赖 `-1 + 1 = 0` 让首个子账户从 index 0 起。Swift 协议 `-> Int` 时保留 `-1` 语义（或返回 `Int?` 由编排器 `(value ?? -1) + 1`），**勿实现成空表返回 0**（会导致首个派生子账户静默跳过 index 0）。
16. **`deriveSubAccount` 互斥不能照搬 `NSLock`、也不能靠 actor 重入**：Kotlin `Mutex.withLock` 是挂起感知锁；临界区含多个 `await`（store/vault/wallet 调用），`NSLock` 阻塞线程且要求同线程 unlock，Swift await 后线程可迁移 → 语义违规 + 协作线程池饥饿风险。**也别把整段流程塞进 actor 方法靠「actor 串行化」**：actor 在 await 点是**可重入**的，两个并发 `derive` 会交错执行（都读到同一 `getMaxIndexByChain` → 都派生 index N → 落库冲突），互斥不成立。**用链式 Task 互斥门**（`DeriveGate.withLock`，见 02 §5）：每次调用排在上一次完成后执行，天然 FIFO 串行；调用方取消不会中断已排队的 body（body 仍执行完），链不破坏。手写 `CheckedContinuation` waiter 队列可作替代但易错（`CheckedContinuation` 是 struct、无引用判等；取消路径 remove+resume 有双 resume 风险），不推荐。

## 3. 测试策略

| 层级 | 方式 | 覆盖 |
| --- | --- | --- |
| Store | 内存 GRDB（临时文件 DatabasePool） | 两表迁移、add/remove/setCurrent/update×4、clearAll（含 current 清空）、观察流（root/sub/traditional 过滤、chain 过滤、subAccounts 按 parentId、current 推 nil、**删除当前账户 → current 推 nil**）、查询（findById/ByAddress×2/findRoot/findNonRoot/getMaxIndexByChain/countSubAccountsByChain/getSameAccountsCount） |
| 编排器 | Fake `AccountStore` + Fake/真实 `SwiftVault` + Fake `SwiftWallet`（派生返回固定结果） | `importSingleAccount` 判重（AddressAlreadyExists）/ 落库成功；`importHdWallet`（根+子落库、`clearExisting` 清库、已存在跳过、PasswordRequired/PasswordRequiredForClear/WrongPassword 分支）；`importSubAccount`（RootAccountNotFound）；`deriveSubAccount`（索引推进、自动跳过已存在、**并发互斥（第二个拿到正确索引）**、调用后 vault 解锁态）；`removeAccount`（WrongPassword、幂等删除、同地址计数 1 才删 vault、调用后 vault 解锁态）；`clearWalletData`（有/无密码分支） |
| Entity 转换 | 单测 | `WalletAccount ↔ 记录` 双向转换（chain BIP44 还原、path 三列 null 语义、isHD/parentId 过滤键） |
| 集成 | demo 接入 | `SwiftAccount` 作为 WalletDemo 的账户层（列表/切换/删除），与 SwiftVault/SwiftWallet 组合 |

> 与 SwiftNft/SwiftDid 同款：单测全部走 Fake + GRDB 内存库（macOS `swift test` 可跑）；真实 SwiftWallet 桥（隐藏 WebView 派生）用例放 iOS 模拟器冒烟。

## 4. 实施清单

- [ ] `Package.swift` 注册 `SwiftAccount` target（依赖 SwiftDappConnect + SwiftVault + SwiftWallet + **GRDB**）
- [ ] `Model`：`AccountOperationResult` / `AccountOperationError` / `ImportHdWalletResult` / `HdChildAccountId` / `DerivedSubAccount` + 单测
- [ ] `Store/AccountStore.swift` 协议（观察流 + CRUD + 查询，镜像 IAccountStore）+ `GRDBAccountStore`（两表迁移 / upsert / ValueObservation / 索引）+ 单测
- [ ] `SwiftAccount.swift` 门面（全部方法镜像 AccountSdk）+ `Util/PathConversion.swift`
- [ ] `AccountManager.swift`：六流程（importSingleAccount / importHdWallet / importSubAccount / deriveSubAccount / removeAccount / clearWalletData）+ Fake store/vault/wallet 单测
- [ ] 接入 `Examples/WalletDemo`：账户层替换 demo 自维护的地址列表（若 demo 扩展示）
