import Foundation
import SwiftCore
@testable import SwiftDappConnect

func makeAccount(address: String, chain: ChainType = .eth, isHD: Bool = false, parentId: String? = nil) -> WalletAccount {
    WalletAccount(address: address, chain: chain, isHD: isHD, parentId: parentId)
}

// MARK: - Account

final class FakeAccountProvider: AccountProvider, @unchecked Sendable {
    let accountsValue: [WalletAccount]
    let currentAccountValue: WalletAccount?
    let onSetCurrentAccount: (String) -> Void

    init(
        accounts: [WalletAccount],
        currentAccount: WalletAccount? = nil,
        onSetCurrentAccount: @escaping (String) -> Void = { _ in }
    ) {
        self.accountsValue = accounts
        self.currentAccountValue = currentAccount
        self.onSetCurrentAccount = onSetCurrentAccount
    }

    var accounts: AsyncStream<[WalletAccount]> {
        AsyncStream { continuation in
            continuation.yield(self.accountsValue)
            continuation.finish()
        }
    }

    var currentAccount: AsyncStream<WalletAccount?> {
        AsyncStream { continuation in
            continuation.yield(self.currentAccountValue)
            continuation.finish()
        }
    }

    func getAccountsByChain(_ chain: ChainType) -> AsyncStream<[WalletAccount]> {
        AsyncStream { continuation in
            continuation.yield(self.accountsValue.filter { $0.chain == chain })
            continuation.finish()
        }
    }

    func getAccountByAddress(_ address: String) async -> WalletAccount? {
        self.accountsValue.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
    }

    func setCurrentAccount(accountId: String) async {
        self.onSetCurrentAccount(accountId)
    }

    func getAccountName(_: String) async -> String? {
        nil
    }
}

// MARK: - Secret

actor SecretRecorder {
    private(set) var privateKeyCalls: [(address: String, origin: String)] = []
    private(set) var secretCalls: [(address: String, origin: String)] = []

    func recordPrivateKey(_ address: String, _ origin: String) {
        self.privateKeyCalls.append((address, origin))
    }

    func recordSecret(_ address: String, _ origin: String) {
        self.secretCalls.append((address, origin))
    }
}

final class FakeSecretProvider: SecretProvider, @unchecked Sendable {
    let recorder: SecretRecorder
    let privateKey: String?
    let secret: String?

    init(privateKey: String? = nil, secret: String? = nil, recorder: SecretRecorder = SecretRecorder()) {
        self.privateKey = privateKey
        self.secret = secret
        self.recorder = recorder
    }

    func getPrivateKeyForAddress(_ address: String, origin: String) async throws -> String? {
        await self.recorder.recordPrivateKey(address, origin)
        return self.privateKey
    }

    func getSecretForAddress(_ address: String, origin: String) async throws -> String? {
        await self.recorder.recordSecret(address, origin)
        return self.secret
    }
}

// MARK: - Node

@MainActor
final class FakeNodeProvider: NodeProvider {
    var blockNumber = "0x1"
    var transactionCount = "0x0"
    var gasPrice = "0x1"
    var maxPriorityFee = "0x1"
    var gasEstimate = "0x5208"
    /// P1#3 测试用：非 nil 时 estimateGas 抛该错（模拟 revert/余额不足/节点错误）。
    var gasEstimateError: (any Error)?
    var broadcastHash = "0xhash"
    var rawTxHash = "0xblobhash"
    var sequence: Int64 = 1

    func getRpcUrl(chain _: ChainType) async throws -> String {
        "https://rpc.example.com"
    }

    func getBlockNumber(chain _: ChainType) async throws -> String {
        self.blockNumber
    }

    func getTransactionCount(address _: String, chain _: ChainType) async throws -> String {
        self.transactionCount
    }

    func getGasPrice(chain _: ChainType) async throws -> String {
        self.gasPrice
    }

    func getMaxPriorityFeePerGas(chain _: ChainType) async throws -> String {
        self.maxPriorityFee
    }

    func estimateGas(txParams _: JsonObjectParams, chain _: ChainType) async throws -> String {
        if let gasEstimateError {
            throw gasEstimateError
        }
        return self.gasEstimate
    }

    func broadcastTransaction(signedTx _: String, chain _: ChainType) async throws -> String {
        self.broadcastHash
    }

    func sendRawTransaction(signedBlob _: String) async throws -> String {
        self.rawTxHash
    }

    func fetchSequence(address _: String) async throws -> Int64 {
        self.sequence
    }
}

// MARK: - Chain

final class FakeChainProvider: ChainProvider, @unchecked Sendable {
    let supportedChainsValue: [ChainType]
    let currentChainValue: ChainType
    let confirm: (ChainType, ChainType, String) -> Bool

    init(
        supportedChains: [ChainType],
        currentChain: ChainType,
        confirm: @escaping (ChainType, ChainType, String) -> Bool = { _, _, _ in true }
    ) {
        self.supportedChainsValue = supportedChains
        self.currentChainValue = currentChain
        self.confirm = confirm
    }

    var supportedChains: [ChainType] {
        get async { self.supportedChainsValue }
    }

    var currentChain: ChainType {
        get async { self.currentChainValue }
    }

    func requestChainSwitch(fromChain: ChainType, toChain: ChainType, origin: String) async -> Bool {
        self.confirm(fromChain, toChain, origin)
    }
}

// MARK: - WalletSigning

@MainActor
final class FakeWalletSigning: WalletSigning {
    var ethSignedTx = "0xsigned"
    var swtcSignedBlob = "0xblob"
    var multiSignResult = "0xms"
    var messageSignature = "0xmsg"

    func personalSign(privateKey _: String, message _: String) async throws -> String {
        "0xsig"
    }

    func recoverPersonalSignature(message _: String, signature _: String) async throws -> String {
        "0xaddr"
    }

    func signTypedData(privateKey _: String, typedData _: String, version _: String) async throws -> String {
        "0xtyped"
    }

    func recoverTypedSignature(data _: String, signature _: String, version _: String) async throws -> String {
        "0xaddr"
    }

    func getEncryptionPublicKey(privateKey _: String) async throws -> String {
        "0xpub"
    }

    func decrypt(privateKey _: String, encryptedData _: String) async throws -> String {
        "plaintext"
    }

    func signEthTransaction(privateKey _: String, txParams _: [String: Any]) async throws -> String {
        self.ethSignedTx
    }

    func signSwtcTransaction(txParams _: [String: Any], secret _: String) async throws -> String {
        self.swtcSignedBlob
    }

    func multiSign(tx _: [String: Any], secret _: String) async throws -> String {
        self.multiSignResult
    }

    func signMessage(from _: String, data _: String, secret _: String) async throws -> String {
        self.messageSignature
    }

    func buildSwtcNftTransfer(address: String, to: String, tokenId: String, memo: String) async throws -> [String: Any] {
        ["Account": address, "Destination": to, "TokenID": tokenId, "Memo": memo]
    }
}

// MARK: - 中间件 fakes（WebAppInterface 路由测试用）

@MainActor
final class FakeEthMiddleware: EthMiddlewareProtocol {
    var currentChain: ChainType = .bsc
    var requestAccountsResult: [String] = []
    var requestAccountsError: Error?
    var switchError: Error?
    var chainSwitched = false
    private(set) var recordedOrigins: [String] = []
    private(set) var setCurrentChainCalls: [ChainType] = []

    func setCurrentChain(_ chain: ChainType) {
        self.currentChain = chain
        self.setCurrentChainCalls.append(chain)
    }

    func setOnAccountSwitched(_: @escaping (String) -> Void) {}
    func setRequestAccountsCallback(_: RequestAccountsCallback?) {}

    func requestAccounts(origin: String) async throws -> [String] {
        self.recordedOrigins.append(origin)
        if let requestAccountsError {
            throw requestAccountsError
        }
        return self.requestAccountsResult
    }

    func accounts() async throws -> [String] {
        self.requestAccountsResult
    }

    func getChainId() -> String {
        "0x38"
    }

    func getBlockNumber() async throws -> String {
        "0x1"
    }

    func personalSign(address _: String, message _: String, origin _: String) async throws -> String {
        "0xsig"
    }

    func recoverPersonalSignature(message _: String, signature _: String) async throws -> String {
        "0xaddr"
    }

    func signTypedData(address _: String, typedData _: String, version _: String, origin _: String) async throws -> String {
        "0xtyped"
    }

    func getEncryptionPublicKey(address _: String, origin _: String) async throws -> String {
        "0xpub"
    }

    func decrypt(address _: String, encryptedData _: String, origin _: String) async throws -> String {
        "plaintext"
    }

    func signTransaction(txParams _: [String: Any], origin _: String) async throws -> SignTransactionResult {
        SignTransactionResult(data: "0xsigned", chain: self.currentChain)
    }

    func sendTransaction(txParams _: [String: Any], origin _: String) async throws -> String {
        "0xhash"
    }

    func switchEthereumChain(chainIdHex _: String, origin _: String) async throws {
        self.chainSwitched = true
        if let switchError {
            throw switchError
        }
    }
}

@MainActor
final class FakeSwtcMiddleware: SwtcMiddlewareProtocol {
    var requestAccountsResult: [String] = []
    var requestAccountsError: Error?

    func setRequestAccountsCallback(_: RequestAccountsCallback?) {}

    func requestAccounts(origin _: String) async throws -> [String] {
        if let requestAccountsError {
            throw requestAccountsError
        }
        return self.requestAccountsResult
    }

    func sendTransaction(txParams _: [String: Any], origin _: String) async throws -> String {
        "0xblobhash"
    }

    func multiSign(msParams _: [String: Any], origin _: String) async throws -> [String: Any] {
        ["result": "0xms"]
    }

    func signMessage(from _: String, data _: String, origin _: String) async throws -> String {
        "0xsig"
    }

    func getPublicKey(address _: String, origin _: String) async throws -> String {
        "0xpub"
    }
}
