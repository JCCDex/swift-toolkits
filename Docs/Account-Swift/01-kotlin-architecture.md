# 01 · Kotlin 架构解析（:account）

> 对齐依据：`kotlin-toolkits` `account/`（2026-08 抓取，main 分支）。源码路径：`account/src/main/java/com/jccdex/toolkits/account/`。

## 1. 模块定位

**钱包账户元数据**的本地持久化与业务编排。**不含私钥**（私钥由 `:vault` 管理）；派生由 `:wallet` 提供。共享领域模型来自 `:core`（`WalletAccount` / `ChainType` / `Path`）。

## 2. 类结构与职责

| 类 | 职责 |
| --- | --- |
| `AccountSdk` | 门面：包装 `IAccountStore`，暴露观察流 / CRUD / 查询 / `orchestrator(vaultRepository)`；`get(context)` 进程内单例、`create(context)`、`createForTest(store)` |
| `AccountOrchestrator` | 业务编排：`importSingleAccount` / `importHdWallet` / `importSubAccount` / `deriveSubAccount` / `removeAccount` / `clearWalletData`；依赖 `IAccountStore` + `VaultRepository` + `WalletSdk` |
| `AccountOperationResult<T>` | `Success(value)` / `Error(error)` 密封类；`AccountOperationError`：`AddressAlreadyExists` / `AccountAlreadyExists` / `RootAccountNotFound` / `PasswordRequired` / `PasswordRequiredForClear` / `WrongPassword` / `Failure(cause)` |
| `IAccountStore` | 存储协议：观察流 ×7（accounts / currentAccount / rootHDAccounts / subHDAccounts / traditionalAccounts / getAccountsByChain / getSubAccountsOf）+ CRUD + 查询（findByAddress ×2 / findRootAccountByAddress / findNonRootAccount / findById / getMaxIndexByChain / countSubAccountsByChain / getSameAccountsCount / clearAllAccounts） |
| `RoomAccountStore` | Room 实现（`AccountDao` + `CurrentAccountDao`） |
| `AccountEntity` | `accounts` 表：`id`(PK, String) / `address` / `chain`(Long = BIP44 code) / `name` / `isHD` / `parentId?` / `pathAccount?` / `pathChange?` / `pathIndex?` / `publicKey`；`toWalletAccount()` / `fromWalletAccount()` |
| `CurrentAccountEntity` | `current_account` 表：固定 `id = 1` 单行 + `accountId` |
| `ImportHdWalletResult` | `rootAccountId` + `children: List<HdChildAccountId(chain, accountId)>` |
| `DerivedSubAccount` | `address` / `chain` / `path` / `rootAccountId` / `publicKey`（deriveSubAccount 的产出，可再 `importSubAccount` 落库） |

## 3. AccountSdk 门面方法面

| 类别 | 方法 |
| --- | --- |
| 观察 | `accounts` / `currentAccount` / `rootHDAccounts` / `subHDAccounts` / `traditionalAccounts`（Flow）/ `getAccountsByChain(chain)` / `getSubAccountsOf(parentId)` |
| 写 | `addAccount` / `addAccounts` / `removeAccount(accountId)` / `setCurrentAccount(accountId)` / `updateAccountName` / `updateAccountNameByAddress` / `updatePublicKey` / `updateParentId` / `clearAllAccounts` |
| 查 | `findById` / `findByAddress(address, chain)` / `findByAddress(address)` / `findRootAccountByAddress` / `findNonRootAccount(address, chain)` / `getMaxIndexByChain(parentId, chain)` / `countSubAccountsByChain` / `getSameAccountsCount(address)` / `getCurrentAccountId` |
| 编排 | `orchestrator(vaultRepository)` → `AccountOrchestrator` |

## 4. AccountOrchestrator 流程要点

- **`importSingleAccount(derived, chain, name, isHD, parentId)`**：`findNonRootAccount` 判重（`AddressAlreadyExists`）→ `persistVaultMaterial`（mnemonic/secret/privateKey 三选一落 vault）→ 构造 `WalletAccount` 落 store → `Success(accountId)`。
- **`importHdWallet(hdResult, name, password, clearExisting, clearExistingPassword)`**：
  1. `clearExisting` 时先 `vault.clearAllData(pwd)`（vault 已有密码须带当前密码，`WrongPassword` 映射）+ `store.clearAllAccounts()`；
  2. 根地址判重（`AccountAlreadyExists`）；
  3. vault 无密码 → `initializePassword(password)`（缺密码 → `PasswordRequired`）；
  4. 根账户（`Path(0,0,0,0)`，chain=SWTC）`importMnemonic` + 落 store；
  5. 遍历 `hdResult.accounts`：未知链（`fromBip44Code` 为 null）**整体跳过（连 vault key 也不导入）**；其余子账户 key 全部收进批量 `importPrivateKeys`（含 store 已存在者，vault 侧按 address 判重去重）+ 子账户落 store（已存在跳过），产出 `children`。
- **`importSubAccount(derived, name)`**：根存在（`RootAccountNotFound`）→ 复用 `importSingleAccount`（isHD=true, parentId=root）。
- **`deriveSubAccount(chain, rootAccountId, index?)`**：`Mutex` 互斥；`vault.getMnemonicUnlocked(rootAddress)` → `WalletSdk.deriveChild(mnemonic, chain, index)`；自动索引时跳过已存在地址（`findNonRootAccount` 循环 +1）；`vault.importPrivateKey` 落库；返回 `DerivedSubAccount`（**不落 accounts 表**，由调用方 `importSubAccount`）；`finally` 里 `mnemonic.fill(0)` 清零。
- **`removeAccount(accountId, password)`**：先 `vault.verifyPassword`（M-14，`WrongPassword`）；账户不存在 → `Success`（幂等删除）；`getSameAccountsCount == 1` 时同步 `vault.removeAddress`（同地址多账户只删 vault 一次）。
- **`clearWalletData(password)`**：vault 有密码 → `clearAllData(password)`（错 → `WrongPassword`），无密码直接清；再 `store.clearAllAccounts()`。

## 5. 存储细节

- `accounts` 表：`id` 主键（String，非自增——由调用方生成，如 `address#chain` 或 UUID）；`chain` 存 **BIP44 code**（Long），读时 `ChainType.fromBip44Code` 还原；`parentId` 指向 HD 根；`path*` 三列可为 null（传统账户无路径）；`publicKey` 非空。
- `current_account` 表：固定单行 `id = 1`（upsert 覆盖），`accountId` 外键语义（软引用，不建 FK 约束）。
- DAO 查询：按 `isHD`/`parentId` 过滤（root = isHD && parentId IS NULL；sub = isHD && parentId IS NOT NULL；traditional = isHD == 0）；`getMaxIndexByChain` = 该父账户 + 链下 `MAX(pathIndex)`（空表 NULL → 存储层 `?: -1`）；`getSameAccountsCount` = 同 `address` 计数（跨链同地址判重用）。

## 6. 测试基线

`AccountSdkTest` / `AccountOrchestratorTest` / `RoomAccountStoreTest` / `AccountDaoTest` / `AccountEntityTest` / `AccountRoomDatabaseTest`：

- 判重（AddressAlreadyExists / AccountAlreadyExists）、密码分支（PasswordRequired / PasswordRequiredForClear / WrongPassword）、幂等删除、HD 导入（根+子、clearExisting 清库、已存在跳过）、派生（索引推进、自动跳过已存在）、store CRUD/观察/查询、entity 双向转换。
