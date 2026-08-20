import Foundation
import SwiftCore

/// 账户元数据存储协议（镜像 Kotlin `IAccountStore`；纯存储，编排逻辑归 `AccountManager`）。
public protocol AccountStore: AnyObject, Sendable {

    // MARK: 观察（ValueObservation → AsyncStream；首帧推送当前值）

    func observeAccounts() -> AsyncStream<[WalletAccount]>
    func observeCurrentAccount() -> AsyncStream<WalletAccount?>
    func observeRootHDAccounts() -> AsyncStream<[WalletAccount]>
    func observeSubHDAccounts() -> AsyncStream<[WalletAccount]>
    func observeTraditionalAccounts() -> AsyncStream<[WalletAccount]>
    func observeAccounts(chain: ChainType) -> AsyncStream<[WalletAccount]>
    func observeSubAccounts(of parentId: String) -> AsyncStream<[WalletAccount]>

    // MARK: 写（对齐 Kotlin suspend）

    /// 冲突（重复 id）即抛错（对齐 Kotlin Room `@Insert` ABORT 语义；勿 upsert 静默覆盖）。
    func addAccount(_ account: WalletAccount) async throws
    /// 批量插入；任一行冲突即整体抛错（调用方（编排器）先判重）。
    func addAccounts(_ accounts: [WalletAccount]) async throws
    func removeAccount(accountId: String) async throws
    /// 账户不存在抛错（对齐 Kotlin `NoSuchElementException`；不做 no-op）。
    func setCurrentAccount(accountId: String) async throws
    func updateAccountName(accountId: String, name: String) async throws
    func updateAccountNameByAddress(address: String, name: String) async throws
    func updatePublicKey(accountId: String, publicKey: String) async throws
    func updateParentId(accountId: String, parentId: String) async throws
    /// 清空 accounts 与 current_account（对齐 Kotlin `deleteAllAccounts + deleteAll`）。
    func clearAllAccounts() async throws

    // MARK: 查

    func findById(_ id: String) async throws -> WalletAccount?
    func findByAddress(_ address: String, chain: ChainType) async throws -> WalletAccount?
    func findByAddress(_ address: String) async throws -> WalletAccount?
    func findRootAccountByAddress(_ address: String) async throws -> WalletAccount?
    func findNonRootAccount(address: String, chain: ChainType) async throws -> WalletAccount?
    /// 该父账户 + 链下最大子账户 index；**无行 → -1**（Kotlin `MAX(pathIndex) ?: -1`，
    /// `deriveSubAccount` 依赖 -1 + 1 = 0 让首个子账户落在 index 0）。
    func getMaxIndexByChain(parentId: String, chain: ChainType) async throws -> Int
    /// 该父账户 + 链下子账户数；无行 → 0。
    func countSubAccountsByChain(parentId: String, chain: ChainType) async throws -> Int
    func getCurrentAccountId() async throws -> String?
    /// 跨链同地址计数（同地址不同链算多次；判重/删 vault 用）。
    func getSameAccountsCount(address: String) async throws -> Int
}
