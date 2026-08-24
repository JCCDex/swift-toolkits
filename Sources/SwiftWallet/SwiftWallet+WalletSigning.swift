import Foundation
import SwiftDappConnect

// MARK: - SwiftWallet: WalletSigning

/// `SwiftWallet` 作为 `SwiftDappConnect` 中间件的真实签名后端
/// （替代 demo 桩实现 `DemoWalletSigning`）。
extension SwiftWallet: WalletSigning {
    public func personalSign(privateKey: String, message: String) async throws -> String {
        try await self.personalSign(privateKey: privateKey, data: message)
    }

    public func recoverPersonalSignature(message: String, signature: String) async throws -> String {
        try await self.recoverPersonalSignature(data: message, signature: signature)
    }

    public func signTypedData(privateKey: String, typedData: String, version: String) async throws -> String {
        try await self.signTypedData(privateKey: privateKey, data: typedData, version: version)
    }

    // recoverTypedSignature(data:signature:version:) / getEncryptionPublicKey(privateKey:) /
    // multiSign(tx:secret:) 与类自身方法签名一致，协议需求已由 SwiftWallet 原生方法满足，
    // 无需（也不能）在扩展中重复声明。

    public func decrypt(privateKey: String, encryptedData: String) async throws -> String {
        try await self.decrypt(privateKey: privateKey, data: encryptedData)
    }

    public func signEthTransaction(privateKey: String, txParams: [String: Any]) async throws -> String {
        try await self.signEthTransaction(privateKey: privateKey, tx: txParams)
    }

    public func signSwtcTransaction(txParams: [String: Any], secret: String) async throws -> String {
        try await self.signSwtcTransaction(tx: txParams, secret: secret)
    }

    public func signMessage(from: String, data: String, secret: String) async throws -> String {
        try await self.signMessage(address: from, message: data, secret: secret)
    }

    /// 协议要求返回 `[String: Any]`（tx 字典），桥返回序列化 JSON 字符串，这里解析
    /// （原始字符串版本见 `buildSwtcNftTransferRaw`，review SwiftWallet P1#3）。
    /// 解析失败不再返回 `[:]` 吞错（下游 `SwtcMiddleware` 只注入 Sequence 就签名，
    /// 空字典会签出无意义交易）——抛错带上下文，见 review SwiftWallet P1#1。
    public func buildSwtcNftTransfer(address: String, to: String, tokenId: String, memo: String) async throws -> [String: Any] {
        let raw: String = try await self.buildSwtcNftTransferRaw(address: address, to: to, tokenId: tokenId, memo: memo)
        guard
            let data = raw.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw SwiftWalletError.invalidResponse(
                "buildSwtcNftTransfer: bridge returned non-JSON-object: \(Self.sanitizedPreview(raw))"
            )
        }
        return object
    }

    /// 错误信息带响应预览（截断；不落原始 payload——可能含地址/密钥上下文）。
    private static func sanitizedPreview(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }
}
