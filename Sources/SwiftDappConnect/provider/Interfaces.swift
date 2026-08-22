import Foundation
import SwiftCore

/// 跨 actor 传参的 JSON 对象包装：`[String: Any]` 非 Sendable，无法直接跨隔离域传递
/// （`estimateGas` 等需从 MainActor 中间件传往后台 NodeProvider，见 review #5）。
/// 构造后只读；值本身是 JSONSerialization 兼容字典，不暴露可变引用。
public struct JsonObjectParams: @unchecked Sendable {
    public let value: [String: Any]

    public init(_ value: [String: Any]) {
        self.value = value
    }
}

/// 跨 actor 传参的 JSON 数组包装（`[Any]?` 非 Sendable，同上；NFT whiteList 用）。
public struct JsonArrayParams: @unchecked Sendable {
    public let value: [Any]?

    public init(_ value: [Any]?) {
        self.value = value
    }
}

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

/// NodeProvider 交换 `JsonObjectParams`（estimateGas），**非 @MainActor**：
/// 网络 I/O 移到协作线程池，MainActor 中间件 await 时不阻塞主线程（见 review #5；
/// 原标 @MainActor 仅是为通过 Swift 6 严格并发——参数经 Sendable 包装后无需）。
public protocol NodeProvider: Sendable {
    func getRpcUrl(chain: ChainType) async throws -> String
    func getBlockNumber(chain: ChainType) async throws -> String
    func getTransactionCount(address: String, chain: ChainType) async throws -> String
    func getGasPrice(chain: ChainType) async throws -> String
    func getMaxPriorityFeePerGas(chain: ChainType) async throws -> String
    func estimateGas(txParams: JsonObjectParams, chain: ChainType) async throws -> String
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

/// NftProvider 交换 `JsonArrayParams`（whiteList），**非 @MainActor**（网络 I/O 移出主线程，
/// 见 review #5）。
public protocol NftProvider: Sendable {
    func getEvmNfts(address: String, chainIdHex: String, whiteList: JsonArrayParams?) async throws -> EvmNftResult
    func getSwtcNfts(address: String) async throws -> SwtcNftResult
}
