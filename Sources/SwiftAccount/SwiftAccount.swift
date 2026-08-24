import SwiftCore
import SwiftVault
import SwiftWallet

/// 账户元数据门面（镜像 Kotlin `AccountSdk`）：观察流 / CRUD / 查询 / 编排器。
/// 自由线程（非 @MainActor）；AsyncStream 观察 + async 写/查。
/// 门面方法是对 `store` 的一行转发（便捷层；需要协议级操作时可直接用 `store`，
/// 见 review SwiftAccount P1#4——不随 `AccountStore` 协议漂移的替代是直接暴露 store）。
public final class SwiftAccount: Sendable {
    /// 底层账户元数据存储（公开：门面方法即其转发，需协议级操作直接用此属性）。
    private let store: any AccountStore

    /// 账户编排器（成员变量；vault + wallet 为 init 必填依赖，不可为 nil）。
    /// ⚠️ 使用前须先启动 SwiftWallet 桥（对应 Kotlin `WalletSdk.initialize/start`）。
    public let accountManager: AccountManager

    /// - Parameters:
    ///   - store: 账户元数据存储。
    ///   - vault: 密钥库（必填；`AccountManager` 导入/派生/删除依赖）。
    ///   - wallet: 地址派生器（必填；`SwiftWallet` 或测试 Fake）。
    public init(
        store: any AccountStore,
        vault: VaultRepository,
        wallet: any WalletDeriving
    ) {
        self.store = store
        self.accountManager = AccountManager(store: store, vault: vault, wallet: wallet)
    }

    // MARK: - 观察

    public var accounts: AsyncStream<[WalletAccount]> {
        self.store.observeAccounts()
    }

    public var currentAccount: AsyncStream<WalletAccount?> {
        self.store.observeCurrentAccount()
    }

    public var rootHDAccounts: AsyncStream<[WalletAccount]> {
        self.store.observeRootHDAccounts()
    }

    public var subHDAccounts: AsyncStream<[WalletAccount]> {
        self.store.observeSubHDAccounts()
    }

    public var traditionalAccounts: AsyncStream<[WalletAccount]> {
        self.store.observeTraditionalAccounts()
    }

    public func accounts(chain: ChainType) -> AsyncStream<[WalletAccount]> {
        self.store.observeAccounts(chain: chain)
    }

    public func subAccounts(of parentId: String) -> AsyncStream<[WalletAccount]> {
        self.store.observeSubAccounts(of: parentId)
    }

    // MARK: - 写

    public func addAccount(_ account: WalletAccount) async throws {
        try await self.store.addAccount(account)
    }

    public func addAccounts(_ accounts: [WalletAccount]) async throws {
        try await self.store.addAccounts(accounts)
    }

    /// 删除账户**元数据**（裸 store 删除：不验密、不清理 vault）。
    /// ⚠️ 与 `AccountManager.removeAccount(accountId:password:)`（编排删除：验密 + 同步删
    /// vault 密钥）同名异构——本方法改名 `removeAccountMeta` 消除歧义，见 review
    /// SwiftAccount P1#2；走门面删账户且要清理密钥时用 `accountManager.removeAccount`。
    public func removeAccountMeta(accountId: String) async throws {
        try await self.store.removeAccount(accountId: accountId)
    }

    public func setCurrentAccount(accountId: String) async throws {
        try await self.store.setCurrentAccount(accountId: accountId)
    }

    public func updateAccountName(accountId: String, name: String) async throws {
        try await self.store.updateAccountName(accountId: accountId, name: name)
    }

    public func updateAccountNameByAddress(address: String, name: String) async throws {
        try await self.store.updateAccountNameByAddress(address: address, name: name)
    }

    public func updatePublicKey(accountId: String, publicKey: String) async throws {
        try await self.store.updatePublicKey(accountId: accountId, publicKey: publicKey)
    }

    public func updateParentId(accountId: String, parentId: String) async throws {
        try await self.store.updateParentId(accountId: accountId, parentId: parentId)
    }

    public func clearAllAccounts() async throws {
        try await self.store.clearAllAccounts()
    }

    // MARK: - 查

    public func findById(_ id: String) async throws -> WalletAccount? {
        try await self.store.findById(id)
    }

    public func findByAddress(_ address: String, chain: ChainType) async throws -> WalletAccount? {
        try await self.store.findByAddress(address, chain: chain)
    }

    public func findByAddress(_ address: String) async throws -> WalletAccount? {
        try await self.store.findByAddress(address)
    }

    public func findRootAccountByAddress(_ address: String) async throws -> WalletAccount? {
        try await self.store.findRootAccountByAddress(address)
    }

    public func findNonRootAccount(address: String, chain: ChainType) async throws -> WalletAccount? {
        try await self.store.findNonRootAccount(address: address, chain: chain)
    }

    public func getMaxIndexByChain(parentId: String, chain: ChainType) async throws -> Int {
        try await self.store.getMaxIndexByChain(parentId: parentId, chain: chain)
    }

    public func countSubAccountsByChain(parentId: String, chain: ChainType) async throws -> Int {
        try await self.store.countSubAccountsByChain(parentId: parentId, chain: chain)
    }

    public func getCurrentAccountId() async throws -> String? {
        try await self.store.getCurrentAccountId()
    }

    public func getSameAccountsCount(address: String) async throws -> Int {
        try await self.store.getSameAccountsCount(address: address)
    }
}
