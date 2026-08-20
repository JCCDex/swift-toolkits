import Foundation

/// 请求账户前的用户授权回调（M-06：必须设置，未设置视为用户拒绝）。
public typealias RequestAccountsCallback = @MainActor (String) async -> Bool

/// DID 文档变更通知（如 ipfs_personalSign 发布后）。
public typealias DidDocumentMutationListener = () -> Void

@MainActor
public protocol EthMiddlewareProtocol {
    var currentChain: ChainType { get }
    func setCurrentChain(_ chain: ChainType)
    func setOnAccountSwitched(_ callback: @escaping (String) -> Void)
    func setRequestAccountsCallback(_ callback: RequestAccountsCallback?)

    func requestAccounts(origin: String) async throws -> [String]
    func getChainId() -> String
    func getBlockNumber() async throws -> String
    func personalSign(address: String, message: String, origin: String) async throws -> String
    func recoverPersonalSignature(message: String, signature: String) async throws -> String
    func signTypedData(address: String, typedData: String, version: String, origin: String) async throws -> String
    func getEncryptionPublicKey(address: String, origin: String) async throws -> String
    func decrypt(address: String, encryptedData: String, origin: String) async throws -> String
    func signTransaction(txParams: [String: Any], origin: String) async throws -> SignTransactionResult
    func sendTransaction(txParams: [String: Any], origin: String) async throws -> String
    func switchEthereumChain(chainIdHex: String, origin: String) async throws
}

@MainActor
public protocol SwtcMiddlewareProtocol {
    func setRequestAccountsCallback(_ callback: RequestAccountsCallback?)
    func requestAccounts(origin: String) async throws -> [String]
    func sendTransaction(txParams: [String: Any], origin: String) async throws -> String
    func multiSign(msParams: [String: Any], origin: String) async throws -> [String: Any]
    func signMessage(from: String, data: String, origin: String) async throws -> String
    func getPublicKey(address: String, origin: String) async throws -> String
}

/// 交易签名能力抽象（对应 Kotlin `WalletSdk` 的调用面），宿主接线。
@MainActor
public protocol WalletSigning {
    func personalSign(privateKey: String, message: String) async throws -> String
    func recoverPersonalSignature(message: String, signature: String) async throws -> String
    func signTypedData(privateKey: String, typedData: String, version: String) async throws -> String
    func recoverTypedSignature(data: String, signature: String, version: String) async throws -> String
    func getEncryptionPublicKey(privateKey: String) async throws -> String
    func decrypt(privateKey: String, encryptedData: String) async throws -> String
    func signEthTransaction(privateKey: String, txParams: [String: Any]) async throws -> String
    func signSwtcTransaction(txParams: [String: Any], secret: String) async throws -> String
    func multiSign(tx: [String: Any], secret: String) async throws -> String
    func signMessage(from: String, data: String, secret: String) async throws -> String
    func buildSwtcNftTransfer(address: String, to: String, tokenId: String, memo: String) async throws -> [String: Any]
}

/// DID 能力抽象（对应 Kotlin 注入的 `DidSdk`），宿主接线。
@MainActor
public protocol DidSDK {
    func didGenerateBase58PublicKey(privateKey: String) async throws -> (publicKeyBase58: String, type: String)
    func signCredential(privateKey: String, vcJson: String) async throws -> String
    func ipfsPersonalSign(privateKey: String, data: [Int]) async throws -> String
    func ipfsGetPublicKey(privateKey: String) async throws -> String
}
