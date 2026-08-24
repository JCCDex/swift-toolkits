import Foundation
import SwiftCore

// MARK: - 钱包模型（镜像 Kotlin `WalletModels.kt`，Decodable 对应）

/// 密钥对（JS 返回，字符串形式）
public struct Keypair: Codable, Sendable, Equatable {
    public let privateKey: String
    public let publicKey: String

    public init(privateKey: String, publicKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

/// 助记词
public struct Mnemonic: Codable, Sendable, Equatable {
    public let value: String
    public let language: String

    public init(value: String, language: String) {
        self.value = value
        self.language = language
    }
}

/// 派生子账户
public struct SubWallet: Codable, Sendable, Equatable {
    public let chain: Int64
    public let address: String
    public let path: Path
    public let keypair: Keypair

    public init(chain: Int64, address: String, path: Path, keypair: Keypair) {
        self.chain = chain
        self.address = address
        self.path = path
        self.keypair = keypair
    }
}

/// HD 钱包结果（从助记词生成根账户 + 多链子账户）
public struct GenerateHDWalletResult: Codable, Sendable, Equatable {
    public let mnemonic: String
    public let address: String
    public let language: String
    public let keypair: Keypair
    public let accounts: [SubWallet]

    public init(
        mnemonic: String,
        address: String,
        language: String,
        keypair: Keypair,
        accounts: [SubWallet] = []
    ) {
        self.mnemonic = mnemonic
        self.address = address
        self.language = language
        self.keypair = keypair
        self.accounts = accounts
    }

    /// 自定义 Decodable：JS 缺 `accounts` 键时按 `[]` 处理——合成 `init(from:)` 会忽略
    /// 属性默认值直接 `keyNotFound`（见 review SwiftWallet P1#2）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mnemonic = try container.decode(String.self, forKey: .mnemonic)
        self.address = try container.decode(String.self, forKey: .address)
        self.language = try container.decode(String.self, forKey: .language)
        self.keypair = try container.decode(Keypair.self, forKey: .keypair)
        self.accounts = try container.decodeIfPresent([SubWallet].self, forKey: .accounts) ?? []
    }
}

/// 传统派生结果（从助记词 / 私钥派生）
public struct TraditionalDeriveResult: Codable, Sendable, Equatable {
    public let address: String
    public let keypair: Keypair
    public let mnemonic: Mnemonic?
    public let secret: String?
    public let path: Path?
    public let sourcePrivateKey: String?

    public init(
        address: String,
        keypair: Keypair,
        mnemonic: Mnemonic? = nil,
        secret: String? = nil,
        path: Path? = nil,
        sourcePrivateKey: String? = nil
    ) {
        self.address = address
        self.keypair = keypair
        self.mnemonic = mnemonic
        self.secret = secret
        self.path = path
        self.sourcePrivateKey = sourcePrivateKey
    }
}
