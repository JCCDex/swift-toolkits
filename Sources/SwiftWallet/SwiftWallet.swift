import Foundation
import SwiftCore
import SwiftWebviewBridge

// MARK: - SwiftWallet

/// Kotlin `object WalletSdk` 的 Swift 版：隐藏 WebView 钱包桥的类型化封装。
///
/// 覆盖：助记词生成/校验、子账户派生、地址派生与校验、SWTC/EVM 交易构造与签名、
/// EVM 消息签名与验签、加密/解密。
@MainActor
public final class SwiftWallet: WalletDeriving {
    public static let shared = SwiftWallet()

    private let bridge: any EngineBridge
    private var started = false

    /// 真实桥（默认）：`WebViewBridgeEngine` 加载 `wallet-bridge.html`；
    /// 测试/宿主可注入自定义桥（对应 Kotlin `installBridgeForTest`）。
    public init(bridge: any EngineBridge = WebViewBridgeEngine(bridgeFileName: "wallet-bridge.html")) {
        self.bridge = bridge
    }

    // MARK: - 生命周期

    /// 幂等：初始化并启动隐藏 WebView（加载 wallet-bridge.html）。
    /// 未调用前调用其它方法抛 `SwiftWalletError.notInitialized`。
    public func start() throws {
        guard !self.started else { return }
        try self.bridge.start()
        self.started = true
    }

    public func destroy() {
        self.bridge.destroy()
        self.started = false
    }

    // MARK: - 助记词 / 派生

    public func validateMnemonic(_ mnemonic: String, language: String = "english") async throws -> Bool {
        let raw = try await self.call(method: "validateMnemonic", params: [
            "mnemonic": mnemonic, "language": language
        ])
        return Self.boolFromRaw(raw)
    }

    public func generateMnemonic(length: Int = 128, language: String = "english") async throws -> Mnemonic {
        try await self.callTyped(method: "generateMnemonic", params: [
            "length": length, "language": language
        ])
    }

    public func deriveChild(
        mnemonic: String,
        chain: Int64,
        account: Int = 0,
        change: Int = 0,
        index: Int = 0,
        language: String = "english"
    ) async throws -> SubWallet {
        try await self.callTyped(method: "deriveChild", params: [
            "mnemonic": mnemonic, "chain": chain,
            "account": account, "change": change, "index": index,
            "language": language
        ])
    }

    public func hdWalletFromMnemonic(
        _ mnemonic: String,
        chains: [Int64] = [],
        language: String = "english"
    ) async throws -> GenerateHDWalletResult {
        try await self.callTyped(method: "hdWalletFromMnemonic", params: [
            "mnemonic": mnemonic, "chains": chains, "language": language
        ])
    }

    public func deriveFromMnemonic(
        _ mnemonic: String,
        chain: Int64,
        account: Int = 0,
        change: Int = 0,
        index: Int = 0,
        language: String = "english"
    ) async throws -> TraditionalDeriveResult {
        try await self.callTyped(method: "deriveFromMnemonic", params: [
            "mnemonic": mnemonic, "chain": chain,
            "account": account, "change": change, "index": index,
            "language": language
        ])
    }

    public func deriveFromPrivateKey(_ privateKey: String, chain: Int64) async throws -> TraditionalDeriveResult {
        try await self.callTyped(method: "deriveFromPrivateKey", params: [
            "privateKey": privateKey, "chain": chain
        ])
    }

    public func validatePrivateKey(_ privateKey: String, chain: Int64) async throws -> Bool {
        let raw = try await self.call(method: "validatePrivateKey", params: [
            "privateKey": privateKey, "chain": chain
        ])
        return Self.boolFromRaw(raw)
    }

    // MARK: - SWTC 交易

    public func buildSwtcPayment(
        address: String,
        amount: String,
        to: String,
        token: String,
        memo: String
    ) async throws -> String {
        try await self.call(method: "buildSwtcPayment", params: [
            "address": address, "amount": amount, "to": to,
            "token": token, "memo": memo
        ])
    }

    /// 桥原始版本：返回序列化 JSON 字符串（协议实现 `buildSwtcNftTransfer` 解析为字典，
    /// 见 review SwiftWallet P1#3——原与协议方法同名仅返回类型不同，易混淆）。
    public func buildSwtcNftTransferRaw(
        address: String,
        to: String,
        tokenId: String,
        memo: String
    ) async throws -> String {
        try await self.call(method: "buildSwtcNftTransfer", params: [
            "address": address, "to": to, "tokenId": tokenId, "memo": memo
        ])
    }

    public func buildSwtcCreateOrder(
        address: String,
        amount: String,
        base: String,
        counter: String,
        sum: String,
        type: String,
        platform: String? = nil,
        issuer: String? = nil
    ) async throws -> String {
        var params: [String: Any] = [
            "address": address, "amount": amount, "base": base,
            "counter": counter, "sum": sum, "type": type
        ]
        platform.map { params["platform"] = $0 }
        issuer.map { params["issuer"] = $0 }
        return try await self.call(method: "buildSwtcCreateOrder", params: params)
    }

    public func buildSwtcCancelOrder(address: String, sequence: Int64) async throws -> String {
        try await self.call(method: "buildSwtcCancelOrder", params: [
            "address": address, "sequence": sequence
        ])
    }

    public func isValidAddress(_ address: String) async throws -> Bool {
        let raw = try await self.call(method: "isValidAddress", params: ["address": address])
        return Self.boolFromRaw(raw)
    }

    public func signSwtcTransaction(tx: [String: Any], secret: String) async throws -> String {
        try await self.call(method: "signSwtcTransaction", params: ["tx": tx, "secret": secret])
    }

    public func signMessage(address: String, message: String, secret: String) async throws -> String {
        try await self.call(method: "signMessage", params: [
            "address": address, "message": message, "secret": secret
        ])
    }

    public func signTransaction(tx: [String: Any], secret: String) async throws -> String {
        try await self.call(method: "signTransaction", params: ["tx": tx, "secret": secret])
    }

    public func multiSign(tx: [String: Any], secret: String) async throws -> String {
        try await self.call(method: "multiSign", params: ["tx": tx, "secret": secret])
    }

    // MARK: - EVM 签名

    public func personalSign(privateKey: String, data: String) async throws -> String {
        try await self.call(method: "personalSign", params: ["privateKey": privateKey, "data": data])
    }

    public func signTypedData(privateKey: String, data: String, version: String) async throws -> String {
        try await self.call(method: "signTypedData", params: [
            "privateKey": privateKey, "data": data, "version": version
        ])
    }

    public func recoverTypedSignature(data: String, signature: String, version: String) async throws -> String {
        try await self.call(method: "recoverTypedSignature", params: [
            "data": data, "signature": signature, "version": version
        ])
    }

    public func recoverPersonalSignature(data: String, signature: String) async throws -> String {
        try await self.call(method: "recoverPersonalSignature", params: [
            "data": data, "signature": signature
        ])
    }

    public func encryptionPublicKey(privateKey: String) async throws -> String {
        try await self.call(method: "getEncryptionPublicKey", params: ["privateKey": privateKey])
    }

    public func decrypt(privateKey: String, data: String) async throws -> String {
        try await self.call(method: "decrypt", params: ["privateKey": privateKey, "data": data])
    }

    public func signEthTransaction(privateKey: String, tx: [String: Any]) async throws -> String {
        try await self.call(method: "signEthTransaction", params: ["privateKey": privateKey, "tx": tx])
    }

    // MARK: - 私有

    private func ensureStarted() throws {
        guard self.started else { throw SwiftWalletError.notInitialized }
    }

    private func call(method: String, params: [String: Any]?) async throws -> String {
        try self.ensureStarted()
        return try await self.bridge.call(method: method, params: params)
    }

    private func callTyped<T: Decodable>(method: String, params: [String: Any]?) async throws -> T {
        try self.ensureStarted()
        return try await self.bridge.callTyped(method: method, params: params, asType: T.self)
    }

    /// 对齐 Kotlin `String.toBoolean()`：仅 "true"（忽略大小写与首尾空白）为 true。
    private static func boolFromRaw(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }
}

public enum SwiftWalletError: Error, Equatable, Sendable {
    case notInitialized
    /// 桥响应解析失败（携带截断预览；非预期数据形态，见 review SwiftWallet P1#1）。
    case invalidResponse(String)
}
