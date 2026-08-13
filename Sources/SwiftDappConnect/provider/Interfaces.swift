import Foundation

// ── 核心 Provider（与 Kotlin provider.Interfaces 对齐） ──

public protocol AccountProvider: Sendable {
    var accounts: AsyncStream<[WalletAccount]> { get }
    var currentAccount: AsyncStream<WalletAccount?> { get }
    func getAccountsByChain(_ chain: ChainType) -> AsyncStream<[WalletAccount]>
    func getAccountByAddress(_ address: String) async -> WalletAccount?
    func setCurrentAccount(accountId: String) async
    func getAccountName(_ address: String) async -> String?
}

public protocol SecretProvider: Sendable {
    func getPrivateKeyForAddress(_ address: String, origin: String) async throws -> String?
    func getSecretForAddress(_ address: String, origin: String) async throws -> String?
}

/// NodeProvider 交换 `[String: Any]`（estimateGas），标 @MainActor 以通过 Swift 6 严格并发。
@MainActor
public protocol NodeProvider {
    func getRpcUrl(chain: ChainType) async throws -> String
    func getBlockNumber(chain: ChainType) async throws -> String
    func getTransactionCount(address: String, chain: ChainType) async throws -> String
    func getGasPrice(chain: ChainType) async throws -> String
    func getMaxPriorityFeePerGas(chain: ChainType) async throws -> String
    func estimateGas(txParams: [String: Any], chain: ChainType) async throws -> String
    func broadcastTransaction(signedTx: String, chain: ChainType) async throws -> String
    func sendRawTransaction(signedBlob: String) async throws -> String
    func fetchSequence(address: String) async throws -> Int64
}

// ── 链切换 ──

public protocol ChainProvider: Sendable {
    func requestChainSwitch(fromChain: ChainType, toChain: ChainType, origin: String) async -> Bool
    var supportedChains: [ChainType] { get async }
    var currentChain: ChainType { get async }
}

public protocol ChainConfigProvider: Sendable {
    func getChainId(chain: ChainType) -> Int64?
}

// ── NFT（可选） ──

/// NftProvider 交换 `[Any]?`（whiteList），标 @MainActor 以通过 Swift 6 严格并发。
@MainActor
public protocol NftProvider {
    func getEvmNfts(address: String, chainIdHex: String, whiteList: [Any]?) async throws -> EvmNftResult
    func getSwtcNfts(address: String) async throws -> SwtcNftResult
}
