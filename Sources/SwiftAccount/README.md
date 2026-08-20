# SwiftAccount

`kotlin-toolkits` 中 `:account` 模块的 Swift 移植：账户元数据管理（列表/当前选中/查询）与导入编排（`AccountManager`）。依赖 `SwiftCore`（模型）、`SwiftVault`（密钥落库）、`SwiftWallet`（地址派生，经 `WalletDeriving` 协议注入）。设计文档见 [Docs/Account-Swift/README.md](../../Docs/Account-Swift/README.md)。

## 组成

| 类型 | 职责 |
| --- | --- |
| `SwiftAccount` | 门面：观察流 / CRUD / 查询 + 非 Optional 的 `accountManager` 成员 |
| `AccountManager` | 六条流程：`importSingleAccount` / `importHdWallet` / `importSubAccount` / `deriveSubAccount` / `removeAccount` / `clearWalletData` |
| `AccountStore` | 存储协议（观察 / 写 / 查，纯存储，编排逻辑归 Manager） |
| `GRDBAccountStore` | GRDB 实现：`accounts` + `current_account` 表，raw SQL（与 Kotlin Room 逐条对齐） |
| `AccountOperationResult` / `AccountOperationError` | 编排结果/错误（Success/Failure 命名对齐 Kotlin，不用 Swift `Result`） |

## 快速开始

```swift
import SwiftAccount
import SwiftCore
import SwiftVault
import SwiftWallet
import GRDB

// 存储：GRDB（对应 Kotlin Room account.db）
let store = try GRDBAccountStore(database: DatabasePool(path: ".../account.sqlite"))

let account = SwiftAccount(
    store: store,
    vault: VaultRepository(storageURL: vaultURL),   // 必填（不可为 nil）
    wallet: SwiftWallet()                            // 必填（实现 WalletDeriving）
)
let manager = account.accountManager

// 列表 / 当前选中：观察流驱动 UI（首帧即当前值；current_account 表持久化，重启自动恢复）
for await accounts in account.accounts { render(accounts) }
for await current in account.currentAccount { render(current) }

// 导入单账户（助记词派生；内部判重 → 密钥落 vault → 元数据落 store）
try wallet.start()
let mnemonic = try await wallet.generateMnemonic()
let derived = try await wallet.deriveFromMnemonic(mnemonic: mnemonic.value, chain: ChainType.eth.bip44Code)
let result = await manager.importSingleAccount(
    derived: TraditionalDeriveResult(
        address: derived.address,
        keypair: derived.keypair,
        mnemonic: mnemonic,
        path: derived.path
    ),
    chain: .eth,
    name: "Demo Wallet",
    isHD: false,
    parentId: nil
)
if case let .success(accountId) = result {
    try? await account.setCurrentAccount(accountId: accountId)   // 设为当前选中
}
```

## 设计要点（与 Kotlin 对齐）

1. **稳定 id = `address#bip44Code`**：非随机 UUID——随机 id 破坏判重/计数/删 vault 语义，重复导入靠唯一约束显式报错（见 04 坑 #1）。
2. **冲突即抛错**：`addAccount`/`addAccounts` 走 GRDB insert（ABORT 语义），不做 upsert 静默覆盖；编排器先判重（见 04 坑 #14）。
3. **`getMaxIndexByChain` 空表 → -1**：`deriveSubAccount` 依赖 -1 + 1 = 0 让首个子账户落在 index 0（见 04 坑 #15）。
4. **`findNonRootAccount` SQL 含 `((isHD = 1 AND parentId IS NOT NULL) OR isHD = 0)`**：与 Kotlin 一致；`importSingleAccount`/`importSubAccount` 用它判重（不判根）。
5. **`DeriveGate` 互斥**：`deriveSubAccount` 用链式 Task 串行（对应 Kotlin `Mutex`）；`NSLock` 跨 await 会死锁、actor 在 await 点可重入都会破坏互斥（见 04 坑 #16）。
6. **`removeAccount` 幂等 + vault 清理**：账户不存在返回成功；同地址仅此一条时同步删 vault 密钥（`getSameAccountsCount == 1`）。
7. **`clearWalletData` 须当前密码**：vault 已有密码时必须传 `password`，不得把 nil 透传给 `clearAllData`（SwiftVault 缺省 nil 不验密直接清库，见 02 设计稿 importHdWallet 段）。
8. **密钥三选一落库**：`mnemonic`（+pathPrefix）> `secret` > `privateKey`，对应 Kotlin `persistVaultMaterial`；`importSubAccount` 不碰私钥（地址已在派生阶段入 vault）。
9. **`importHdWallet` 根账户 chain = SWTC**：字面根路径 `m/44'/0'/0'/0/0` 仅作 pathPrefix（Kotlin 字面 `Path(chain: 0, …)`），`path.chain` 不落库；可选 `clearExisting` 清空重导；`deriveSubAccount` 结束时 vault 处于解锁态（`getMnemonic` 走 `ensureUnlocked` 自动解锁），宿主按需 `lock()`（见 04 坑 #6）。

## 模块结构

```text
Sources/SwiftAccount/
├── SwiftAccount.swift               // 门面：观察流 / CRUD / 查询 + accountManager 成员
├── AccountManager.swift             // 六条流程 + DeriveGate（链式 Task 互斥）
├── AccountModels.swift              // AccountOperationResult/Error、ImportHdWalletResult、DerivedSubAccount
└── Store/
    ├── AccountStore.swift           // 协议：观察 / 写 / 查
    └── GRDBAccountStore.swift       // GRDB 实现：accounts / current_account 表（raw SQL）
```

测试对齐 Kotlin 四个用例集（`GRDBAccountStoreTests` 16 / `AccountManagerTests` 16 / `SwiftAccountFacadeTests` 3 / `AccountEntityConversionTests` 4），地址派生用 `FakeWalletDeriving` 注入，不依赖真实 WebView 桥。
