import Foundation

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

/// BIP44 派生路径段（chain = BIP44 链码，与 SwiftDappConnect `ChainType.bip44Code` 数值一致）
public struct Path: Codable, Sendable, Equatable {
    public let chain: Int64
    public let account: Int
    public let change: Int
    public let index: Int

    public init(chain: Int64, account: Int = 0, change: Int = 0, index: Int = 0) {
        self.chain = chain
        self.account = account
        self.change = change
        self.index = index
    }

    /// `m/44'/<chain>'/<account>'/<change>/<index>`（与 Kotlin `Path.toString()` 一致）
    public var derivationPath: String {
        "m/44'/\(self.chain)'/\(self.account)'/\(self.change)/\(self.index)"
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
