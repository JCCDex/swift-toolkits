import Foundation
import SwiftCore

/// SWTC 中间件：swtc_* RPC 方法。
@MainActor
public final class SwtcMiddleware: SwtcMiddlewareProtocol {
    private let accountProvider: any AccountProvider
    private let secretProvider: any SecretProvider
    private let nodeProvider: any NodeProvider
    private let signing: any WalletSigning

    private var requestAccountsCallback: RequestAccountsCallback?

    public init(
        accountProvider: any AccountProvider,
        secretProvider: any SecretProvider,
        nodeProvider: any NodeProvider,
        signing: any WalletSigning
    ) {
        self.accountProvider = accountProvider
        self.secretProvider = secretProvider
        self.nodeProvider = nodeProvider
        self.signing = signing
    }

    public func setRequestAccountsCallback(_ callback: RequestAccountsCallback?) {
        self.requestAccountsCallback = callback
    }

    public func requestAccounts(origin: String) async throws -> [String] {
        guard let callback = requestAccountsCallback else {
            throw DAppConnectError.userRejected("RequestAccountsCallback is not set")
        }
        guard await callback(origin) else {
            throw DAppConnectError.userRejected("User rejected the requestAccounts request")
        }

        let accounts = await accountProvider.accounts.firstValue() ?? []
        return accounts
            .filter { $0.chain.bip44Code == ChainType.swtc.bip44Code && !$0.isHDRoot }
            .map(\.address)
    }

    public func sendTransaction(txParams: [String: Any], origin: String) async throws -> String {
        guard !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DAppConnectError.internalError("origin must not be blank for sendTransaction")
        }
        guard let account = txParams["Account"] as? String else {
            throw DAppConnectError.internalError("Missing Account in transaction params")
        }

        _ = try await self.validateSwtcAccount(account)

        var tx = txParams
        if tx["Sequence"] == nil {
            tx["Sequence"] = try await self.nodeProvider.fetchSequence(address: account)
        }

        let secret = try await requireSecret(address: account, origin: origin)
        let blob = try await signing.signSwtcTransaction(txParams: tx, secret: secret)
        return try await self.nodeProvider.sendRawTransaction(signedBlob: blob)
    }

    public func multiSign(msParams: [String: Any], origin: String) async throws -> [String: Any] {
        guard let account = msParams["account"] as? String else {
            throw DAppConnectError.internalError("Missing account in multi-sign params")
        }
        _ = try await self.validateSwtcAccount(account)

        let secret = try await requireSecret(address: account, origin: origin)
        let tx = (msParams["tx"] as? [String: Any]) ?? [:]
        let result = try await signing.multiSign(tx: tx, secret: secret)
        return ["result": result]
    }

    public func signMessage(from: String, data: String, origin: String) async throws -> String {
        _ = try await self.validateSwtcAccount(from)
        let secret = try await requireSecret(address: from, origin: origin)
        return try await self.signing.signMessage(from: from, data: data, secret: secret)
    }

    public func publicKey(address: String, origin _: String) async throws -> String {
        let account = try await validateSwtcAccount(address)
        return account.publicKey
    }

    /// 原生 UI 路径：宿主已收集密码，直接以密码场景取秘钥并上链。
    public func sendTransactionWithPassword(txParams: [String: Any], password _: String, origin: String) async throws -> String {
        try await self.sendTransaction(txParams: txParams, origin: origin)
    }

    /// 原生 NFT 转账：使用 `WebOrigin.walletInternal` 哨兵 origin（M-18）。
    public func sendNftTransactionWithPassword(
        address: String,
        to: String,
        tokenId: String,
        memo: String,
        password _: String
    ) async throws -> String {
        _ = try await self.validateSwtcAccount(address)

        let rawTx = try await signing.buildSwtcNftTransfer(address: address, to: to, tokenId: tokenId, memo: memo)
        var txParams = rawTx
        if txParams["Sequence"] == nil {
            txParams["Sequence"] = try await self.nodeProvider.fetchSequence(address: address)
        }

        let secret = try await requireSecret(address: address, origin: WebOrigin.walletInternal)
        let blob = try await signing.signSwtcTransaction(txParams: txParams, secret: secret)
        return try await self.nodeProvider.sendRawTransaction(signedBlob: blob)
    }

    // MARK: - 内部

    private func validateSwtcAccount(_ address: String) async throws -> WalletAccount {
        let accounts = await accountProvider.accounts.firstValue() ?? []
        guard let account = accounts.first(where: { $0.address == address }) else {
            throw DAppConnectError.internalError("Account not found in wallet: \(address)")
        }
        guard account.chain.bip44Code == ChainType.swtc.bip44Code else {
            throw DAppConnectError.internalError("Account is not a SWTC account: \(address)")
        }
        return account
    }

    private func requireSecret(address: String, origin: String) async throws -> String {
        guard let secret = try await secretProvider.getSecretForAddress(address, origin: origin) else {
            throw DAppConnectError.internalError("Failed to get secret for address: \(address)")
        }
        return secret
    }
}
