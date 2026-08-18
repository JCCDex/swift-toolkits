import Foundation
import SwiftWebviewBridge

/// 钱包桥抽象（对应 Kotlin `IWalletBridge`）：隐藏 WebView 调用的最小面，
/// 测试可注入 Fake 实现（对应 Kotlin `installBridgeForTest`）。
@MainActor
protocol WalletBridge: AnyObject {
    func start() throws
    func destroy()
    func call(
        method: String,
        params: [String: Any]?,
        timeoutMs: TimeInterval,
        readyWaitMs: TimeInterval
    ) async throws -> String
    func callAs<T: Decodable>(
        method: String,
        params: [String: Any]?,
        as type: T.Type,
        timeoutMs: TimeInterval,
        readyWaitMs: TimeInterval
    ) async throws -> T
}

/// 真实桥：复用 SwiftWebviewBridge 的隐藏 WebView（内置 wallet-bridge.html 与钱包 JS 资产）。
@MainActor
final class EngineWalletBridge: WalletBridge {
    private let engine = WebviewBridgeEngine.shared

    func start() throws {
        self.engine.initialize(config: WebviewBridgeConfig.bridge(named: "wallet-bridge"))
        try self.engine.start()
    }

    func destroy() {
        self.engine.destroy()
    }

    func call(
        method: String,
        params: [String: Any]?,
        timeoutMs: TimeInterval,
        readyWaitMs: TimeInterval
    ) async throws -> String {
        try await self.engine.callJsMethod(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    func callAs<T: Decodable>(
        method: String,
        params: [String: Any]?,
        as type: T.Type,
        timeoutMs: TimeInterval,
        readyWaitMs: TimeInterval
    ) async throws -> T {
        try await self.engine.callJsMethodAs(
            method: method,
            params: params,
            as: type,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }
}

// MARK: - SwiftWallet

/// Kotlin `object WalletSdk` 的 Swift 版：隐藏 WebView 钱包桥的类型化封装。
///
/// 覆盖：助记词生成/校验、子账户派生、地址派生与校验、SWTC/EVM 交易构造与签名、
/// EVM 消息签名与验签、加密/解密。
@MainActor
public final class SwiftWallet {
    public static let shared = SwiftWallet()

    private let bridge: any WalletBridge
    private var started = false

    /// 真实桥（默认）
    public init() {
        self.bridge = EngineWalletBridge()
    }

    /// 测试注入（对应 Kotlin `installBridgeForTest`）
    init(bridge: any WalletBridge) {
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
        try await self.callAs(method: "generateMnemonic", params: [
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
        try await self.callAs(method: "deriveChild", params: [
            "mnemonic": mnemonic, "chain": chain,
            "account": account, "change": change, "index": index,
            "language": language
        ])
    }

    public func hdWalletFromMnemonic(
        mnemonic: String,
        chains: [Int64] = [],
        language: String = "english"
    ) async throws -> GenerateHDWalletResult {
        try await self.callAs(method: "hdWalletFromMnemonic", params: [
            "mnemonic": mnemonic, "chains": chains, "language": language
        ])
    }

    public func deriveFromMnemonic(
        mnemonic: String,
        chain: Int64,
        account: Int = 0,
        change: Int = 0,
        index: Int = 0,
        language: String = "english"
    ) async throws -> TraditionalDeriveResult {
        try await self.callAs(method: "deriveFromMnemonic", params: [
            "mnemonic": mnemonic, "chain": chain,
            "account": account, "change": change, "index": index,
            "language": language
        ])
    }

    public func deriveFromPrivateKey(privateKey: String, chain: Int64) async throws -> TraditionalDeriveResult {
        try await self.callAs(method: "deriveFromPrivateKey", params: [
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

    public func buildSwtcNftTransfer(
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

    public func getEncryptionPublicKey(privateKey: String) async throws -> String {
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
        return try await self.bridge.call(
            method: method, params: params, timeoutMs: 30000, readyWaitMs: 15000
        )
    }

    private func callAs<T: Decodable>(method: String, params: [String: Any]?) async throws -> T {
        try self.ensureStarted()
        return try await self.bridge.callAs(
            method: method, params: params, as: T.self, timeoutMs: 30000, readyWaitMs: 15000
        )
    }

    /// 对齐 Kotlin `String.toBoolean()`：仅 "true"（忽略大小写与首尾空白）为 true。
    private static func boolFromRaw(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }
}

public enum SwiftWalletError: Error, Equatable {
    case notInitialized
}
