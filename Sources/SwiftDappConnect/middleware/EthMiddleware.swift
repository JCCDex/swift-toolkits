import Foundation
import SwiftCore

/// EVM 中间件：eth_*/personal_*/wallet_switchEthereumChain 等 RPC 方法。
@MainActor
public final class EthMiddleware: EthMiddlewareProtocol {
    private let accountProvider: any AccountProvider
    private let secretProvider: any SecretProvider
    private let nodeProvider: any NodeProvider
    private let chainProvider: (any ChainProvider)?
    private let signing: any WalletSigning

    private var requestAccountsCallback: RequestAccountsCallback?
    private var onAccountSwitched: ((String) -> Void)?

    public private(set) var currentChain: ChainType

    public init(
        accountProvider: any AccountProvider,
        secretProvider: any SecretProvider,
        nodeProvider: any NodeProvider,
        chainProvider: (any ChainProvider)? = nil,
        initialChain: ChainType = .bsc,
        signing: any WalletSigning
    ) {
        self.accountProvider = accountProvider
        self.secretProvider = secretProvider
        self.nodeProvider = nodeProvider
        self.chainProvider = chainProvider
        self.currentChain = initialChain
        self.signing = signing
    }

    public func setRequestAccountsCallback(_ callback: RequestAccountsCallback?) {
        self.requestAccountsCallback = callback
    }

    public func setOnAccountSwitched(_ callback: @escaping (String) -> Void) {
        self.onAccountSwitched = callback
    }

    public func setCurrentChain(_ chain: ChainType) {
        self.currentChain = chain
    }

    // MARK: - RPC

    public func requestAccounts(origin: String) async throws -> [String] {
        guard let callback = requestAccountsCallback else {
            throw DAppConnectError.userRejected("RequestAccountsCallback is not set")
        }
        guard await callback(origin) else {
            throw DAppConnectError.userRejected("User rejected the requestAccounts request")
        }

        let accounts = await accountProvider.accounts.firstValue() ?? []
        return accounts
            .filter { $0.chain == self.currentChain && !$0.isHDRoot }
            .map(\.address)
    }

    public func getChainId() -> String {
        let chainId = self.currentChain.evmChainId ?? 1
        return "0x" + String(chainId, radix: 16)
    }

    public func getBlockNumber() async throws -> String {
        try await self.nodeProvider.getBlockNumber(chain: self.currentChain)
    }

    public func personalSign(address: String, message: String, origin: String) async throws -> String {
        _ = try await self.validateEvmAddress(address)
        let privateKey = try await requirePrivateKey(address: address, origin: origin)
        return try await self.signing.personalSign(privateKey: privateKey, message: message)
    }

    public func recoverPersonalSignature(message: String, signature: String) async throws -> String {
        try await self.signing.recoverPersonalSignature(message: message, signature: signature)
    }

    public func signTypedData(address: String, typedData: String, version: String, origin: String) async throws -> String {
        _ = try await self.validateEvmAddress(address)
        let privateKey = try await requirePrivateKey(address: address, origin: origin)
        return try await self.signing.signTypedData(privateKey: privateKey, typedData: typedData, version: version)
    }

    public func recoverTypedSignature(data: String, signature: String, version: String) async throws -> String {
        try await self.signing.recoverTypedSignature(data: data, signature: signature, version: version)
    }

    public func getEncryptionPublicKey(address: String, origin: String) async throws -> String {
        _ = try await self.validateEvmAddress(address)
        let privateKey = try await requirePrivateKey(address: address, origin: origin)
        return try await self.signing.getEncryptionPublicKey(privateKey: privateKey)
    }

    public func decrypt(address: String, encryptedData: String, origin: String) async throws -> String {
        _ = try await self.validateEvmAddress(address)
        let privateKey = try await requirePrivateKey(address: address, origin: origin)
        return try await self.signing.decrypt(privateKey: privateKey, encryptedData: encryptedData)
    }

    public func signTransaction(txParams: [String: Any], origin: String) async throws -> SignTransactionResult {
        guard !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DAppConnectError.internalError("origin must not be blank for signTransaction")
        }
        guard let from = txParams["from"] as? String else {
            throw DAppConnectError.internalError("Missing from in transaction params")
        }

        let accounts = await accountProvider.accounts.firstValue() ?? []
        guard let walletAccount = accounts.first(where: {
            $0.address.addressEquals(from)
        }) else {
            throw DAppConnectError.internalError("Account not found in wallet: \(from)")
        }
        guard walletAccount.chain.isEvm else {
            throw DAppConnectError.internalError("Account is not an EVM address: \(from)")
        }

        // chainId 优先级：tx 参数 > 当前链；未知 chainId 回落当前链。
        var tx = txParams
        let chainType: ChainType
        if let chainIdValue = tx["chainId"] as? String {
            let chainId = self.parseChainId(chainIdValue)
            chainType = ChainType.allCases.first(where: { $0.evmChainId == chainId }) ?? self.currentChain
        } else {
            chainType = self.currentChain
        }

        // nonce
        if tx["nonce"] == nil {
            tx["nonce"] = try await self.nodeProvider.getTransactionCount(address: from, chain: chainType)
        }

        let isEip1559 = tx["maxFeePerGas"] != nil || tx["maxPriorityFeePerGas"] != nil
        if isEip1559 {
            tx["type"] = "0x2"
            if self.isZeroOrEmpty(tx["maxPriorityFeePerGas"] as? String) {
                do {
                    tx["maxPriorityFeePerGas"] = try await self.nodeProvider.getMaxPriorityFeePerGas(chain: chainType)
                } catch {
                    tx["maxPriorityFeePerGas"] = "0x1"
                }
            }
            if self.isZeroOrEmpty(tx["maxFeePerGas"] as? String) {
                tx["maxFeePerGas"] = try await self.nodeProvider.getGasPrice(chain: chainType)
            }
            tx.removeValue(forKey: "gasPrice")
        } else {
            if self.isZeroOrEmpty(tx["gasPrice"] as? String) {
                tx["gasPrice"] = try await self.nodeProvider.getGasPrice(chain: chainType)
            }
        }

        // gas / gasLimit
        if tx["gas"] == nil, tx["gasLimit"] == nil {
            do {
                let estimate = try await nodeProvider.estimateGas(txParams: tx, chain: chainType)
                tx["gas"] = estimate
                tx["gasLimit"] = estimate
            } catch {
                tx["gas"] = "0x5208"
                tx["gasLimit"] = "0x5208"
            }
        } else {
            let gasValue = (tx["gas"] as? String) ?? (tx["gasLimit"] as? String) ?? ""
            tx["gas"] = gasValue
            tx["gasLimit"] = gasValue
        }

        // chainId
        if tx["chainId"] == nil {
            guard let chainId = chainType.evmChainId else {
                throw DAppConnectError.internalError("Chain \(chainType.rawValue) does not have an EVM chainId")
            }
            tx["chainId"] = "0x" + String(chainId, radix: 16)
        }

        let privateKey = try await requirePrivateKey(address: from, origin: origin)
        let signedTx = try await signing.signEthTransaction(privateKey: privateKey, txParams: tx)
        return SignTransactionResult(data: signedTx, chain: chainType)
    }

    public func sendTransaction(txParams: [String: Any], origin: String) async throws -> String {
        guard !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DAppConnectError.internalError("origin must not be blank for sendTransaction")
        }
        let result = try await signTransaction(txParams: txParams, origin: origin)
        return try await self.nodeProvider.broadcastTransaction(signedTx: result.data, chain: result.chain)
    }

    public func switchEthereumChain(chainIdHex: String, origin: String) async throws {
        let chainId: Int64
        if let parsed = parseChainIdOptional(chainIdHex) {
            chainId = parsed
        } else {
            throw DAppConnectError.internalError("Invalid chainId format: \(chainIdHex)")
        }

        guard let targetChain = ChainType.allCases.first(where: { $0.evmChainId == chainId }) else {
            throw DAppConnectError.chainNotSupported(chainId: chainId)
        }
        guard targetChain.isEvm else {
            throw DAppConnectError.chainNotSupported(chainId: chainId)
        }

        if self.currentChain == targetChain {
            return
        }

        guard let chainProvider else {
            throw DAppConnectError.internalError("ChainProvider not set")
        }
        let confirmed = await chainProvider.requestChainSwitch(
            fromChain: self.currentChain,
            toChain: targetChain,
            origin: origin
        )
        guard confirmed else {
            throw DAppConnectError.userRejected("User rejected the chain switch request")
        }

        self.currentChain = targetChain

        let targetAccounts = await getAccountsForChain(targetChain)
        guard let firstAccount = targetAccounts.first else {
            return
        }

        let currentAccount = await accountProvider.currentAccount.firstValue() ?? nil
        let sameAddressAccount = currentAccount.flatMap { current in
            targetAccounts.first { $0.address.addressEquals(current.address) }
        }
        let targetAccount = sameAddressAccount ?? firstAccount
        await self.accountProvider.setCurrentAccount(accountId: targetAccount.id)
        self.onAccountSwitched?(targetAccount.address)
    }

    public func getCurrentChainIdHex() -> String {
        let chainId = self.currentChain.evmChainId ?? 1
        return "0x" + String(chainId, radix: 16)
    }

    public func getAccountsForChain(_ chain: ChainType) async -> [WalletAccount] {
        let accounts = await accountProvider.accounts.firstValue() ?? []
        return accounts.filter { $0.chain == chain && !$0.isHDRoot }
    }

    // MARK: - 内部

    private func validateEvmAddress(_ address: String) async throws -> WalletAccount {
        let accounts = await accountProvider.accounts.firstValue() ?? []
        guard let account = accounts.first(where: {
            $0.address.addressEquals(address)
        }) else {
            throw DAppConnectError.internalError("Address not found in wallet: \(address)")
        }
        guard account.chain.isEvm else {
            throw DAppConnectError.internalError("Address is not an EVM address: \(address)")
        }
        return account
    }

    private func requirePrivateKey(address: String, origin: String) async throws -> String {
        guard let key = try await secretProvider.getPrivateKeyForAddress(address, origin: origin) else {
            throw DAppConnectError.internalError("Failed to get private key")
        }
        return key
    }

    private func isZeroOrEmpty(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return true }
        let hex = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        if hex.isEmpty {
            return true
        }
        return Int64(hex, radix: 16).map { $0 == 0 } ?? true
    }

    private func parseChainId(_ value: String) -> Int64 {
        self.parseChainIdOptional(value) ?? 0
    }

    private func parseChainIdOptional(_ value: String) -> Int64? {
        if value.lowercased().hasPrefix("0x") {
            return Int64(String(value.dropFirst(2)), radix: 16)
        }
        return Int64(value)
    }
}
