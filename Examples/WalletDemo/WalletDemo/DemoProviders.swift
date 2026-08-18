import Foundation
import SwiftDappConnect

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

// 本 demo 的 DApp 只调用 web3_clientVersion / eth_requestAccounts（账户已由
// DemoAccountProvider 提供），不访问节点/签名。以下桩仅满足中间件构造要求。

final class DemoSecretProvider: SecretProvider {
    func getPrivateKeyForAddress(_: String, origin _: String) async throws -> String? {
        nil
    }

    func getSecretForAddress(_: String, origin _: String) async throws -> String? {
        nil
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

@MainActor
final class DemoWalletSigning: WalletSigning {
    func personalSign(privateKey _: String, message _: String) async throws -> String {
        ""
    }

    func recoverPersonalSignature(message _: String, signature _: String) async throws -> String {
        ""
    }

    func signTypedData(privateKey _: String, typedData _: String, version _: String) async throws -> String {
        ""
    }

    func recoverTypedSignature(data _: String, signature _: String, version _: String) async throws -> String {
        ""
    }

    func getEncryptionPublicKey(privateKey _: String) async throws -> String {
        ""
    }

    func decrypt(privateKey _: String, encryptedData _: String) async throws -> String {
        ""
    }

    func signEthTransaction(privateKey _: String, txParams _: [String: Any]) async throws -> String {
        ""
    }

    func signSwtcTransaction(txParams _: [String: Any], secret _: String) async throws -> String {
        ""
    }

    func multiSign(tx _: [String: Any], secret _: String) async throws -> String {
        ""
    }

    func signMessage(from _: String, data _: String, secret _: String) async throws -> String {
        ""
    }

    func buildSwtcNftTransfer(address _: String, to _: String, tokenId _: String, memo _: String) async throws -> [String: Any] {
        [:]
    }
}
