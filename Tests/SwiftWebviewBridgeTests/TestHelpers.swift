import Foundation

/// `generateMnemonic` 的返回结构（真实 bridge JS 会返回 `{value, language}`）。
struct MnemonicResult: Decodable, Equatable {
    let value: String
    let language: String
}

/// BIP39 标准测试助记词（128-bit → 12 words），可被真实 bridge JS 校验通过。
let validBip39Mnemonic = """
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
"""
