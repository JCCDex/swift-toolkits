import Foundation
import SwiftCore
import SwiftDappConnect
import SwiftWallet

// MARK: - Demo 钱包状态（地址列表 + 当前地址）

/// 地址列表与当前地址状态：WalletService 维护，DemoAccountProvider 读取，
/// DApp 的 eth_requestAccounts 返回当前地址。
/// 当前地址持久化到 UserDefaults，重启 App 后恢复上次选择，而非默认第一个账户。
@MainActor
final class DemoWalletState: ObservableObject {
    @Published var accounts: [WalletAccount] = []
    @Published var currentAddress: String? {
        didSet { Self.persist(self.currentAddress) }
    }

    func setCurrent(_ address: String) {
        self.currentAddress = address
    }

    var currentAccount: WalletAccount? {
        guard let currentAddress else { return nil }
        return self.accounts.first { $0.address.caseInsensitiveCompare(currentAddress) == .orderedSame }
    }

    // MARK: - 当前地址持久化

    private static let currentAddressKey = "walletdemo.currentAddress"

    /// 上次选择的当前地址（无则 nil）
    static func savedCurrentAddress() -> String? {
        UserDefaults.standard.string(forKey: self.currentAddressKey)
    }

    private static func persist(_ address: String?) {
        if let address {
            UserDefaults.standard.set(address, forKey: self.currentAddressKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.currentAddressKey)
        }
    }
}

// MARK: - Demo 账户 Provider（读 DemoWalletState）

/// 账户 Provider：`accounts` 只返回当前选中账户（EIP-1193 eth_accounts 语义），
/// 在 App 里切换当前地址后，DApp 重新 eth_requestAccounts 即返回新地址。
/// 状态读取统一经 MainActor（DemoWalletState 是 @MainActor 隔离）。
final class DemoAccountProvider: AccountProvider {
    private let state: DemoWalletState

    init(state: DemoWalletState) {
        self.state = state
    }

    var accounts: AsyncStream<[WalletAccount]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let current = self.state.currentAccount
                continuation.yield(current.map { [$0] } ?? [])
                continuation.finish()
            }
        }
    }

    var currentAccount: AsyncStream<WalletAccount?> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield(self.state.currentAccount)
                continuation.finish()
            }
        }
    }

    func getAccountsByChain(_ chain: ChainType) -> AsyncStream<[WalletAccount]> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield(self.state.accounts.filter { $0.chain == chain })
                continuation.finish()
            }
        }
    }

    func getAccountByAddress(_ address: String) async -> WalletAccount? {
        await MainActor.run {
            self.state.accounts.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
        }
    }

    func setCurrentAccount(accountId _: String) async {}

    func getAccountName(_: String) async -> String? {
        nil
    }
}

// MARK: - 其余桩 Provider

// 本 demo 的 DApp 调用 web3_clientVersion / eth_requestAccounts / eth_signTransaction。
// 账户由 DemoAccountProvider 提供；私钥由 DemoSecretProvider 委托 WalletService 从
// SwiftVault 解密（DApp 签名流经中间件 → SecretProvider → SwiftVault）。

/// 密钥 Provider：委托 WalletService 取 SwiftVault 中对应地址的私钥。
/// demo 不做 per-origin 授权（真实 App 应在 SecretProvider 校验 origin↔地址授权）。
final class DemoSecretProvider: SecretProvider {
    private let keyProvider: @MainActor (String) async -> String?

    init(keyProvider: @escaping @MainActor (String) async -> String?) {
        self.keyProvider = keyProvider
    }

    func getPrivateKeyForAddress(_ address: String, origin _: String) async throws -> String? {
        await self.keyProvider(address)
    }

    func getSecretForAddress(_ address: String, origin _: String) async throws -> String? {
        await self.keyProvider(address)
    }
}

@MainActor
final class DemoNodeProvider: NodeProvider {
    func getRpcUrl(chain _: ChainType) async throws -> String {
        "https://rpc.example.com"
    }

    func getBlockNumber(chain _: ChainType) async throws -> String {
        "0x1"
    }

    func getTransactionCount(address _: String, chain _: ChainType) async throws -> String {
        "0x0"
    }

    func getGasPrice(chain _: ChainType) async throws -> String {
        "0x1"
    }

    func getMaxPriorityFeePerGas(chain _: ChainType) async throws -> String {
        "0x1"
    }

    func estimateGas(txParams _: [String: Any], chain _: ChainType) async throws -> String {
        "0x5208"
    }

    func broadcastTransaction(signedTx: String, chain _: ChainType) async throws -> String {
        signedTx
    }

    func sendRawTransaction(signedBlob: String) async throws -> String {
        signedBlob
    }

    func fetchSequence(address _: String) async throws -> Int64 {
        0
    }
}
