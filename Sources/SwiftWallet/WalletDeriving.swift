import Foundation
import SwiftCore

/// 地址派生能力抽象（对应 Kotlin `:wallet` 的 `WalletSdk` 派生面）。
/// `SwiftWallet` 为其实现；`AccountManager` 依赖此协议以便测试注入 Fake。
public protocol WalletDeriving: Sendable {
    /// 从助记词派生子账户（BIP44；`chain` 为 `ChainType.bip44Code`）。
    func deriveChild(
        mnemonic: String,
        chain: Int64,
        account: Int,
        change: Int,
        index: Int,
        language: String
    ) async throws -> SubWallet

    /// 从助记词生成 HD 钱包（根 + 各链子账户）。
    func hdWalletFromMnemonic(
        mnemonic: String,
        chains: [Int64],
        language: String
    ) async throws -> GenerateHDWalletResult

    /// 从私钥派生单账户。
    func deriveFromPrivateKey(privateKey: String, chain: Int64) async throws -> TraditionalDeriveResult
}
