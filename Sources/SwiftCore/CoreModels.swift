import Foundation

// 共享领域模型（对齐 Kotlin `:core`）：`ChainType` / `Path` / `WalletAccount`。
//
// 本模块是 SwiftDappConnect（原 WalletAccount/ChainType/Path 定义处）、SwiftWallet
// （原 Path 重复定义处）、SwiftNft、SwiftDid、SwiftAccount 共享的模型来源——
// 消除跨模块重复（见 Account-Swift 04 坑 #12/#13 的 fromBip44Code/label 补充）。

// MARK: - ChainType

/// BIP44 链标识；`bip44Code` / `evmChainId` / `label` 与 Kotlin core `ChainType` 一致。
public enum ChainType: String, CaseIterable, Sendable {
    case eth
    case bsc
    case polygon
    case arb1
    case base
    case swtc
    case moac

    public var bip44Code: Int64 {
        switch self {
        case .eth: 2_147_483_708
        case .bsc: 2_147_492_654
        case .polygon: 2_147_484_614
        case .arb1: 2_147_492_649
        case .base: 2_147_492_101
        case .swtc: 2_147_483_963
        case .moac: 2_147_483_962
        }
    }

    /// 展示名（对齐 Kotlin `ChainType.label`："Ethereum" / "SWTC" …）。
    public var label: String {
        switch self {
        case .eth: "Ethereum"
        case .bsc: "Binance"
        case .polygon: "Polygon"
        case .arb1: "Arbitrum"
        case .base: "Base"
        case .swtc: "SWTC"
        case .moac: "MOAC"
        }
    }

    public var evmChainId: Int64? {
        switch self {
        case .eth: 1
        case .bsc: 56
        case .polygon: 137
        case .arb1: 42161
        case .base: 8453
        case .swtc: nil
        case .moac: 99
        }
    }

    public var isEvm: Bool {
        self != .swtc
    }

    public var isSwtc: Bool {
        self == .swtc
    }

    /// BIP44 code → ChainType（对齐 Kotlin `ChainType.fromBip44Code`；未知 code → nil）。
    public static func fromBip44Code(_ code: Int64) -> ChainType? {
        allCases.first { $0.bip44Code == code }
    }
}

// MARK: - Path

/// BIP44 派生路径段，与 Kotlin core `Path` 一致；合并 SwiftWallet 侧的
/// `derivationPath`（Kotlin `Path.toString()`）与 `Codable`。
public struct Path: Codable, Sendable, Equatable {
    public let chain: Int64
    public let account: Int
    public let change: Int
    public let index: Int

    public var isRoot: Bool {
        self.account == 0 && self.change == 0 && self.index == 0
    }

    /// `m/44'/<chain>'/<account>'/<change>/<index>`（与 Kotlin `Path.toString()` 一致）。
    public var derivationPath: String {
        "m/44'/\(self.chain)'/\(self.account)'/\(self.change)/\(self.index)"
    }

    public init(chain: Int64, account: Int = 0, change: Int = 0, index: Int = 0) {
        self.chain = chain
        self.account = account
        self.change = change
        self.index = index
    }

    /// 对应 Kotlin `Path.root(chainType:)`：chain = bip44Code，其余为 0。
    public static func root(chainType: ChainType) -> Path {
        Path(chain: chainType.bip44Code)
    }
}

// MARK: - WalletAccount

/// 钱包账户元数据（不含私钥，私钥在 SwiftVault 中）。
public struct WalletAccount: Sendable, Identifiable, Equatable {
    public let id: String
    public let address: String
    public let chain: ChainType
    public let name: String
    public let isHD: Bool
    public let parentId: String?
    public let path: Path?
    public let publicKey: String

    public init(
        id: String = UUID().uuidString,
        address: String,
        chain: ChainType = .eth,
        name: String = "",
        isHD: Bool = false,
        parentId: String? = nil,
        path: Path? = nil,
        publicKey: String = ""
    ) {
        self.id = id
        self.address = address
        self.chain = chain
        self.name = name
        self.isHD = isHD
        self.parentId = parentId
        self.path = path
        self.publicKey = publicKey
    }

    /// 与 Kotlin core `WalletAccount.isRootHD()` 语义一致。
    /// 注意：中间件过滤用 `isHD && parentId == nil`（不查 path），勿混用。
    public var isRootHD: Bool {
        self.isHD && self.path?.isRoot == true && self.parentId == nil
    }
}
