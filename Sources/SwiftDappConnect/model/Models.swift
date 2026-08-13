import Foundation

/// BIP44 链标识，bip44Code / evmChainId 与 Kotlin core `ChainType` 一致。
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
}

/// BIP44 派生路径段，与 Kotlin core `Path` 一致。
public struct Path: Sendable, Equatable {
    public let chain: Int64
    public let account: Int
    public let change: Int
    public let index: Int

    public var isRoot: Bool {
        self.account == 0 && self.change == 0 && self.index == 0
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

/// 交易签名结果。
public struct SignTransactionResult: Sendable, Equatable {
    public let data: String
    public let chain: ChainType

    public init(data: String, chain: ChainType) {
        self.data = data
        self.chain = chain
    }
}

/// DAppConnect 错误，jsonRpcCode 与 Kotlin 异常错误码一致。
public enum DAppConnectError: Error, Equatable {
    case userRejected(String = "User rejected") // 4001（EIP-1193）
    case unauthorized(String = "Account not authorized") // 4100（Kotlin 定义了但路由层从未抛出）
    case chainNotSupported(chainId: Int64) // 4902（EIP-3326）
    case transaction(message: String, code: Int = -1) // 通用/交易错误：Kotlin 路由层统一 -1
    case methodNotSupported
    case bridgeUnavailable
    case missingParameters(String)
    case internalError(String)

    public var jsonRpcCode: Int {
        switch self {
        case .userRejected: 4001
        case .unauthorized: 4100
        case .chainNotSupported: 4902
        case let .transaction(_, code): code
        case .methodNotSupported, .bridgeUnavailable, .missingParameters, .internalError: -1
        }
    }

    public var message: String {
        switch self {
        case let .userRejected(m): m
        case let .unauthorized(m): m
        case let .chainNotSupported(chainId): "Chain with id \(chainId) is not supported"
        case let .transaction(m, _): m
        case .methodNotSupported: "Method not supported"
        case .bridgeUnavailable: "Bridge not available"
        case let .missingParameters(m): m
        case let .internalError(m): m
        }
    }
}

/// 桥接结果值，序列化时区分类型（避免 `0x123` 被 JS 解析成数字）。
public enum RPCResult {
    case null
    case string(String)
    case number(NSNumber)
    case bool(Bool)
    case object([String: Any])
    case array([Any])

    /// 转成可进 JSONSerialization 的原生值（NSNull/String/NSNumber/Bool/[String:Any]/[Any]）。
    public var jsonValue: Any {
        switch self {
        case .null: NSNull()
        case let .string(s): s
        case let .number(n): n
        case let .bool(b): b
        case let .object(o): o
        case let .array(a): a
        }
    }
}

/// DApp 请求（非 Decodable：params 是异构数组，实现时用 JSONSerialization 手写解析）。
public struct DAppRequest {
    public let name: String
    public let network: String
    public let id: String
    public let nonce: String?
    public let params: [Any]?

    public init(name: String, network: String, id: String, nonce: String?, params: [Any]?) {
        self.name = name
        self.network = network
        self.id = id
        self.nonce = nonce
        self.params = params
    }
}

// ── NFT 模型（与 Kotlin provider 数据类一致） ──

public struct EvmNftItem: Sendable, Equatable {
    public let chainId: String
    public let contractAddress: String
    public let tokenId: String
    public let name: String?
    public let imageUrl: String?

    public init(chainId: String, contractAddress: String, tokenId: String, name: String?, imageUrl: String?) {
        self.chainId = chainId
        self.contractAddress = contractAddress
        self.tokenId = tokenId
        self.name = name
        self.imageUrl = imageUrl
    }
}

public struct SwtcNftItem: Sendable, Equatable {
    public let image: String?
    public let issuer: String?
    public let fundCodeName: String?
    public let tokenId: String?
    public let hash: String?

    public init(image: String?, issuer: String?, fundCodeName: String?, tokenId: String?, hash: String?) {
        self.image = image
        self.issuer = issuer
        self.fundCodeName = fundCodeName
        self.tokenId = tokenId
        self.hash = hash
    }
}

public struct EvmNftContractGroup: Sendable, Equatable {
    public let contractAddress: String
    public let tokens: [EvmNftItem]

    public init(contractAddress: String, tokens: [EvmNftItem]) {
        self.contractAddress = contractAddress
        self.tokens = tokens
    }
}

public struct EvmNftResult: Sendable, Equatable {
    public let address: String
    public let total: Int
    public let nfts: [EvmNftContractGroup]

    public init(address: String, total: Int, nfts: [EvmNftContractGroup]) {
        self.address = address
        self.total = total
        self.nfts = nfts
    }
}

public struct SwtcNftResult: Sendable, Equatable {
    public let address: String
    public let total: Int
    public let nfts: [SwtcNftItem]

    public init(address: String, total: Int, nfts: [SwtcNftItem]) {
        self.address = address
        self.total = total
        self.nfts = nfts
    }
}
