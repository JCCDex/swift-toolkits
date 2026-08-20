# 02 · Swift 版设计

> 对齐依据：`kotlin-toolkits` `:account`（见 01 章）。本节 Swift 代码为设计草案，签名与行为对齐 Kotlin 源码，Swift 化差异见 README「与 Kotlin 差异一览」与 04 章。

## 1. 模块布局

```text
Sources/SwiftAccount/
├── SwiftAccount.swift               // 门面：镜像 AccountSdk（观察/CRUD/查询/accountManager）
├── AccountManager.swift        // 业务编排：导入/派生/删除（依赖 SwiftVault + SwiftWallet）
├── AccountModels.swift              // AccountOperationResult / AccountOperationError /
│                                    //   ImportHdWalletResult / HdChildAccountId / DerivedSubAccount
├── Store/AccountStore.swift         // 协议：镜像 IAccountStore（观察流 + CRUD + 查询）
├── Store/GRDBAccountStore.swift     // GRDB 实现：accounts / current_account 两表
└── (Path 已统一到 SwiftCore——不再有双份 Path，无需 PathConversion)
```

`Package.swift` 目标：

```swift
.target(
    name: "SwiftAccount",
    dependencies: [
        .target(name: "SwiftDappConnect"), // 复用 WalletAccount / ChainType / Path（对应 Kotlin :core）
        .target(name: "SwiftVault"),       // 密钥落库/密码校验（对应 Kotlin :vault）
        .target(name: "SwiftWallet"),      // 地址派生（对应 Kotlin :wallet 的 WalletSdk）
        .product(name: "GRDB", package: "GRDB.swift")
    ],
    path: "Sources/SwiftAccount"
)
```

## 2. 存储（GRDB 替代 Room）

`accounts` / `current_account` 两表与 Kotlin Room 同构（见 01 §5）：

```swift
migrator.registerMigration("v1") { db in
    try db.create(table: "accounts") { t in
        t.column("id", .text).primaryKey()
        t.column("address", .text).notNull()
        t.column("chain", .integer).notNull()      // BIP44 code（Int64），读时经 fromBip44Code 还原
        // ⚠️ SwiftDappConnect 仅有 ChainType.bip44Code（enum→Int64 单向）；反向 fromBip44Code(_:)->ChainType?
        //    需补充（SwiftDappConnect 增加 static 或 SwiftAccount 内部扩展 allCases.first{ $0.bip44Code==code }，见 04 坑 #12）
        t.column("name", .text).notNull()
        t.column("isHD", .boolean).notNull()
        t.column("parentId", .text)                // HD 根账户 id；传统账户 null
        t.column("pathAccount", .integer)          // 以下三列可为 null（传统账户无路径）
        t.column("pathChange", .integer)
        t.column("pathIndex", .integer)
        t.column("publicKey", .text).notNull()
    }
    try db.create(table: "current_account") { t in
        t.column("id", .integer).primaryKey()      // 固定 1（单行，upsert 覆盖）
        t.column("accountId", .text).notNull()     // NOT NULL：删除 current 账户时删行，不能置空（见 04 坑 #4）
    }
    // 查询索引：address（判重/按地址查）、parentId（子账户列表/MAX(pathIndex)）
    try db.create(index: "idx_accounts_address", on: "accounts", columns: ["address"])
    try db.create(index: "idx_accounts_parent", on: "accounts", columns: ["parentId"])
}
```

> ⚠️ GRDB 建索引：本仓库 GRDB 7 无 `TableDefinition.index(_:)`，用 `ColumnDefinition.indexed()` 或迁移后 `db.create(index:on:columns:)`（见 Nft-Swift 04 坑 #3 同款）。

## 3. AccountStore 协议（镜像 IAccountStore）

```swift
public protocol AccountStore: AnyObject, Sendable {
    // 观察（ValueObservation → AsyncStream）
    func observeAccounts() -> AsyncStream<[WalletAccount]>
    func observeCurrentAccount() -> AsyncStream<WalletAccount?>
    func observeRootHDAccounts() -> AsyncStream<[WalletAccount]>
    func observeSubHDAccounts() -> AsyncStream<[WalletAccount]>
    func observeTraditionalAccounts() -> AsyncStream<[WalletAccount]>
    func observeAccounts(chain: ChainType) -> AsyncStream<[WalletAccount]>
    func observeSubAccounts(of parentId: String) -> AsyncStream<[WalletAccount]>

    // 写（async throws；对齐 Kotlin suspend）
    func addAccount(_ account: WalletAccount) async throws
    func addAccounts(_ accounts: [WalletAccount]) async throws
    func removeAccount(accountId: String) async throws
    func setCurrentAccount(accountId: String) async throws
    func updateAccountName(accountId: String, name: String) async throws
    func updateAccountNameByAddress(address: String, name: String) async throws
    func updatePublicKey(accountId: String, publicKey: String) async throws
    func updateParentId(accountId: String, parentId: String) async throws
    func clearAllAccounts() async throws

    // 查
    func findById(_ id: String) async throws -> WalletAccount?
    func findByAddress(_ address: String, chain: ChainType) async throws -> WalletAccount?
    func findByAddress(_ address: String) async throws -> WalletAccount?
    func findRootAccountByAddress(_ address: String) async throws -> WalletAccount?
    func findNonRootAccount(address: String, chain: ChainType) async throws -> WalletAccount?
    func getMaxIndexByChain(parentId: String, chain: ChainType) async throws -> Int
    func countSubAccountsByChain(parentId: String, chain: ChainType) async throws -> Int
    func getCurrentAccountId() async throws -> String?
    func getSameAccountsCount(address: String) async throws -> Int
}
```

> **`addAccount`/`addAccounts` 冲突策略**：Kotlin Room `@Insert` 默认 ABORT——重复 `id` 抛 `SQLiteConstraintException`（AccountManager 判重前置，见 01 §4）；Swift 建议同样**冲突即抛错**（`INSERT` 不接 `ON CONFLICT DO UPDATE`），保持「重复 id 是编程错误」语义；仅 `current_account` 用 upsert（固定单行）。若实现选择幂等 upsert，须在协议注释写明偏离。
> Kotlin 的 `Flow` 属性（`accounts`/`currentAccount`/…）在 Swift 用 `observeXxx() -> AsyncStream` 表达（与 SwiftNft/SwiftDid 的 `observeDidDocument` 等命名一致）。
> 空表语义按 Kotlin 对齐：`countSubAccountsByChain`（`COUNT(*)`）无行 → 0；**`getMaxIndexByChain`（`MAX(pathIndex)`）无行 → -1**（Kotlin `?: -1`），这是 `deriveSubAccount` 里 `getMaxIndexByChain + 1` 让首个子账户落在 index 0 的前提——勿实现成 0。
> `setCurrentAccount` 对齐 Kotlin 的「账户不存在抛 `NoSuchElementException`」语义：建议 Swift 同样**抛错**（`AccountStoreError.accountNotFound(accountId)` 或等价错误，在协议注释写明）；不做 no-op——no-op 会掩盖宿主 bug。
> GRDB `ValueObservation.values(in:)` 是 `AsyncSequence`，转 `AsyncStream` 时照抄 SwiftNft `GRDBNftStore.stream(_:in:)` 的包装模式（迭代 Task 在 `onTermination` 时取消）——该 helper 现为 `private`，可复制同款实现或提为共享内部方法；勿直接暴露底层 async sequence 或丢掉取消语义。

## 4. SwiftAccount 门面（镜像 AccountSdk）

```swift
/// 账户元数据门面（自由线程；AsyncStream 观察 + async 写/查）。
public final class SwiftAccount: Sendable {
    private let store: any AccountStore

    public init(store: any AccountStore) {
        self.store = store
    }

    /// 创建编排器（依赖 vault + wallet；仅导入/派生/删除流程需要）。
    /// ⚠️ 使用前须先启动 SwiftWallet 桥（对应 Kotlin `WalletSdk.initialize(context); start()`，
    /// 隐藏 WebView runtime 就绪后才能 deriveChild/hdWalletFromMnemonic）；SwiftWallet 为 @MainActor，
    /// 编排器（自由线程）经 `await` 跨 actor 调用其方法。
    public func accountManager(vault: VaultRepository, wallet: any WalletDeriving) -> AccountManager {
        AccountManager(store: self.store, vault: vault, wallet: wallet)
    }

    public var accounts: AsyncStream<[WalletAccount]> { self.store.observeAccounts() }
    public var currentAccount: AsyncStream<WalletAccount?> { self.store.observeCurrentAccount() }
    public var rootHDAccounts: AsyncStream<[WalletAccount]> { self.store.observeRootHDAccounts() }
    public var subHDAccounts: AsyncStream<[WalletAccount]> { self.store.observeSubHDAccounts() }
    public var traditionalAccounts: AsyncStream<[WalletAccount]> { self.store.observeTraditionalAccounts() }
    public func accounts(chain: ChainType) -> AsyncStream<[WalletAccount]> { self.store.observeAccounts(chain: chain) }
    public func subAccounts(of parentId: String) -> AsyncStream<[WalletAccount]> { self.store.observeSubAccounts(of: parentId) }

    public func addAccount(_ account: WalletAccount) async throws { try await self.store.addAccount(account) }
    public func addAccounts(_ accounts: [WalletAccount]) async throws { try await self.store.addAccounts(accounts) }
    public func removeAccount(accountId: String) async throws { try await self.store.removeAccount(accountId: accountId) }
    public func setCurrentAccount(accountId: String) async throws { try await self.store.setCurrentAccount(accountId: accountId) }
    public func updateAccountName(accountId: String, name: String) async throws { ... }
    public func updateAccountNameByAddress(address: String, name: String) async throws { ... }
    public func updatePublicKey(accountId: String, publicKey: String) async throws { ... }
    public func updateParentId(accountId: String, parentId: String) async throws { ... }
    public func clearAllAccounts() async throws { try await self.store.clearAllAccounts() }

    public func findById(_ id: String) async throws -> WalletAccount? { try await self.store.findById(id) }
    public func findByAddress(_ address: String, chain: ChainType) async throws -> WalletAccount? { ... }
    public func findByAddress(_ address: String) async throws -> WalletAccount? { ... }
    public func findRootAccountByAddress(_ address: String) async throws -> WalletAccount? { ... }
    public func findNonRootAccount(address: String, chain: ChainType) async throws -> WalletAccount? { ... }
    public func getMaxIndexByChain(parentId: String, chain: ChainType) async throws -> Int { ... }
    public func countSubAccountsByChain(parentId: String, chain: ChainType) async throws -> Int { ... }
    public func getCurrentAccountId() async throws -> String? { ... }
    public func getSameAccountsCount(address: String) async throws -> Int { ... }
}
```

> `WalletAccount.id`：SwiftDappConnect 默认 `UUID().uuidString`（随机、**不幂等**）；Kotlin 的 `id` 是调用方控制的业务 id（Room 非自增 String PK）。**编排器落库时必须显式覆盖为稳定 id** `"\(address)#\(chain.bip44Code)"`（同地址同链唯一、天然对应 `findNonRootAccount`/`getSameAccountsCount` 判重键与幂等删除），见 04 坑 #1。

## 5. AccountManager（代码草案）

```swift
public enum AccountOperationError: Error, Equatable {
    case addressAlreadyExists
    case accountAlreadyExists
    case rootAccountNotFound
    case passwordRequired
    case passwordRequiredForClear
    case wrongPassword(String = "Password is wrong")
    /// 底层错误描述；如需保留底层 Error 详情，可加关联 `underlying: Error?`
    /// （不参与 Equatable 比较；Kotlin `Failure(cause: Throwable)` 的 Swift 对应物）。
    case failure(String)
}

/// 有意**不用 Swift `Result<Value, AccountOperationError>`**：Success/Error 命名与 Kotlin
/// `AccountOperationResult` 逐一对齐，且调用方按 `switch` 分支语义更贴近原模块。
public enum AccountOperationResult<Value> {
    case success(Value)
    case failure(AccountOperationError)
}

/// 模型全部为纯值类型，**需标注 `Sendable`**（`AccountOperationResult<Value>: Sendable
/// where Value: Sendable`；`AccountOperationError` / `ImportHdWalletResult` /
/// `HdChildAccountId` / `DerivedSubAccount` 同理）——`withLock` 的 `@Sendable` 闭包与
/// Swift 6 严格并发都要求结果能跨 actor 边界发送。

/// 异步互斥门：对应 Kotlin `Mutex`（仅 deriveSubAccount 互斥）。
/// ⚠️ 不能靠「actor 方法内直接写临界区」实现互斥：actor 在 await 点**可重入**，
/// 两个并发 `derive` 会交错执行（见 04 坑 #16）；也不能用 `NSLock`（阻塞协作线程池
/// + 要求同线程 unlock，临界区跨 await 时线程可迁移）。
/// 用**链式 Task** 串行化：每次调用排在上一次完成后执行，天然 FIFO 互斥，
/// 不依赖 actor 重入语义，也不需要手写续体队列。
private actor DeriveGate {
    private var tail: Task<Void, Never>?

    /// 把 `body` 排到上一笔派生完成后执行；调用方取消不会中断已排队的 body
    /// （body 仍执行完，链不破坏）。
    /// 取消语义：非 throwing `async -> T` 里 `await task.value` 在调用方任务取消时
    /// **传播取消**（不抛错）——调用方任务被取消、body 结果丢弃，但已排队的 body
    /// 照常执行完，后续调用不受影响（链不破坏）。
    func withLock<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let previous = self.tail
        let task = Task { () -> T in
            if let previous {
                _ = await previous.value
            }
            return await body()
        }
        self.tail = Task { _ = await task.value }
        return await task.value
    }
}

public final class AccountManager: Sendable {
    private let store: any AccountStore
    private let vault: VaultRepository
    private let wallet: SwiftWallet
    private let deriveGate = DeriveGate()

    public init(store: any AccountStore, vault: VaultRepository, wallet: SwiftWallet) {
        self.store = store
        self.vault = vault
        self.wallet = wallet
    }

    public func importSingleAccount(
        derived: TraditionalDeriveResult, chain: ChainType, name: String, isHD: Bool, parentId: String?
    ) async -> AccountOperationResult<String> { ... }

    /// - Parameters:
    ///   - password: vault 为空时初始化密码；⚠️ Swift 版显式偏离：Kotlin 的
    ///     「distinct ByteArray / 原地清零」语义在 Data 上不存在，调用方自行保证
    ///     password 与 clearExistingPassword 不是同一份可变缓冲（见 04 坑 #2）。
    ///   - clearExistingPassword: clearExisting=true 且 vault 已有密码时的当前密码。
    public func importHdWallet(
        hdResult: GenerateHDWalletResult, name: String,
        password: Data?, clearExisting: Bool = false, clearExistingPassword: Data? = nil
    ) async -> AccountOperationResult<ImportHdWalletResult> { ... }

    public func importSubAccount(derived: DerivedSubAccount, name: String) async -> AccountOperationResult<String> { ... }

    /// Swift 侧显式偏离：Kotlin 读 vault 会话态 `getMnemonicUnlocked`；SwiftVault 有解锁态
    /// （`isUnlocked`/`unlock`/`lock`/`sessionKey`），但公开读取 `getMnemonic(address:password:)`
    /// 每次经 `ensureUnlocked` 重新校验密码，会话态读取仅以 `getMnemonicInternal` 暴露、未作稳定 API。
    /// 故派生显式传 password，见 04 坑 #6。⚠️ `getMnemonic(address:password:)` 走 `ensureUnlocked`，
    /// vault 锁定时会用该密码解锁并建立会话——调用后 vault 处于解锁态，宿主按需 `lock()`。
    public func deriveSubAccount(
        chain: ChainType, rootAccountId: String, password: Data, index: Int? = nil
    ) async -> AccountOperationResult<DerivedSubAccount> {
        await self.deriveGate.withLock {
            // 流程见下方「流程要点」：根存在校验 → vault.getMnemonic → wallet.deriveChild
            // （自动索引 getMaxIndexByChain + 1 起步、+1 跳过已存在地址）→
            // vault.importPrivateKey → .success(DerivedSubAccount)
        }
    }

    public func removeAccount(accountId: String, password: Data) async -> AccountOperationResult<Void> { ... }
    public func clearWalletData(password: Data) async -> AccountOperationResult<Void> { ... }
}
```

流程要点（与 Kotlin 01 §4 逐条对齐）：

- `importSingleAccount`：`findNonRootAccount` 判重 → `persistVaultMaterial`（`importMnemonic`/`importSecret`/`importPrivateKey` 三选一；`importMnemonic` 的 `pathPrefix` 用 `derived.path?.derivationPath ?? ""`，对齐 Kotlin `?: ""`）→ 构造 `WalletAccount` 落 store（**id 显式覆盖为 `"\(address)#\(chain.bip44Code)"`**，见 04 坑 #1）→ `.success(id)`；异常 → `.failure(.failure(msg))`（`AccountOperationResult.failure` 包 `AccountOperationError.failure`，`runOperation` 等价物）。
- `importHdWallet`：`clearExisting` 分支：`vault.hasPassword()` 且 `clearExistingPassword == nil` → `.passwordRequiredForClear`（**不得把 nil 透传给 `clearAllData`**——SwiftVault 缺省 nil 会不验密直接清库）；有当前密码 → `clearAllData(pwd)`（`IllegalArgumentException`/`VaultError.wrongPassword` → `.wrongPassword`）；vault 无密码 → `clearAllData()`；随后 `clearAllAccounts`；根地址判重；`hasPassword` 为空 → `initializePassword(password)`（nil → `.passwordRequired`）；根（**Kotlin 字面 `Path(chain: 0, account: 0, change: 0, index: 0)`，chain `.swtc`**——注意与 Swift `Path.root(chainType:)` 不同：后者 chain = bip44Code（2147483963）；字面 chain=0 **仅用于 `importMnemonic` 的 `pathPrefix`**（Kotlin `rootPath.toString()` = `"m/44'/0'/0'/0/0"`；Swift 用同字面或 `SwiftWallet.Path.derivationPath` 等价格式生成），`Path.chain` 不落库（表只存 `pathAccount/pathChange/pathIndex`，读回按账户 `chain` 列重建 bip44Code），账户查询一律按 `WalletAccount.chain` 而非 `path.chain`）`importMnemonic` 落 store；子账户命名 `"\(chainType.label)-HD"`（需 SwiftDappConnect 补 `ChainType.label`，见 04 坑 #13）+ 批量 `importPrivateKeys`（全部，含已存在；**未知链整体跳过，连 key 也不导入**）+ 落 store（已存在跳过），产出 `children`。
- `deriveSubAccount`：`await deriveGate.withLock { ... }` 串行执行（链式 Task，见上）；流程：根存在校验 → `vault.getMnemonic(address:password:)` → `wallet.deriveChild(mnemonic:chain: chain.bip44Code, index:)`（自动索引 `(getMaxIndexByChain + 1)` 起步、+1 时跳过已存在地址）→ `vault.importPrivateKey` → `.success(DerivedSubAccount)`；⚠️ 该流程结束时 vault 处于解锁态（`getMnemonic` 走 `ensureUnlocked` 会自动解锁），宿主按需 `lock()`，见 04 坑 #6。
- `removeAccount`：先 `vault.verifyPassword`（错 → `.wrongPassword`）；账户不存在 → `.success(())`（幂等）；`getSameAccountsCount == 1` → `vault.removeAddress`。
- `clearWalletData`：`hasPassword` 分支 + `clearAllAccounts`。

## 6. 并发与安全要点

- **自由线程**：`SwiftAccount`/`AccountStore` 不加 `@MainActor`（AsyncStream 观察、GRDB DatabasePool 线程安全）；`VaultRepository` 是 **actor**（调用需 `await`）；派生能力经 **`WalletDeriving` 协议**注入（`SwiftWallet` conform，测试可 Fake——实现决策，见 README 差异表）。
- **@MainActor 接线**：`SwiftWallet` 门面是 `@MainActor`，`AccountManager` 调 `deriveChild`/`hdWalletFromMnemonic` 经 `await` 跨 actor（Swift 6 严格并发允许）；编排器自身不要求 MainActor。
- **写路径互斥**：仅 `deriveSubAccount` 需要互斥（对应 Kotlin `Mutex`），用 actor 互斥门 `DeriveGate`（链式 Task 串行，见 §5），**不用 `NSLock`**、**不靠 actor 方法直接写临界区**（await 点可重入，见 04 坑 #16）；其余写操作幂等或由 store 冲突策略保证。
- **密码安全**：`Data` 不提供 Kotlin `ByteArray.fill(0)` 的原地清零——编排器不复制密码缓冲（显式偏离，文档注明）；宿主应避免复用同一 `Data` 作 password 与 clearExistingPassword。
- **私钥明文边界**：编排器内部只把派生 keypair 的**私钥字节**传给 `vault.importPrivateKey`（SwiftVault 加密落盘），自身不保留明文；`deriveSubAccount` 的 mnemonic 读自 vault（SwiftVault 解密返回 `Data`，用完由调用方置空——Swift 无自动清零）。

## 7. 与 SwiftWallet / SwiftVault 的接线（真实 API）

- `SwiftWallet.deriveChild(mnemonic:chain:account:change:index:language:)`（`chain: Int64` = `chainType.bip44Code`，`@MainActor`）/ `hdWalletFromMnemonic(mnemonic:chains:[Int64]:language:)` / `deriveFromPrivateKey(privateKey:chain:Int64:)` → `SubWallet` / `GenerateHDWalletResult` / `TraditionalDeriveResult`（含 `Keypair`/`Mnemonic`/`SubWallet`，字段与 Kotlin `:wallet` 一致）；
- `VaultRepository`：`initializePassword` / `verifyPassword` / `hasPassword` / `importMnemonic` / `importPrivateKey(s)` / `importSecret` / `removeAddress` / `clearAllData` / `getMnemonic(address:password:)`；
- Path 双份：SwiftDappConnect.Path（core）↔ SwiftWallet.Path（wallet），`Util/PathConversion.swift` 提供互转（对应 Kotlin `toCorePath`/`toWalletPath`）。
