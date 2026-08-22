import Foundation
import SwiftCore

// MARK: - 展示/解析 DTO（镜像 Kotlin :nft model/NftModels.kt，commit f77b59f）

/// NFT 展示模型（镜像 Kotlin `Nft` 8 字段；字段名 `contract` 而非 `contractAddress`）。
public struct Nft: Codable, Sendable, Equatable {
    public let contract: String
    public let tokenId: String
    public let name: String
    public let uri: String
    public let issuanceDate: String
    public let image: String?
    public let hasLocal: Bool
    public let chainId: Int64?

    public init(
        contract: String,
        tokenId: String,
        name: String,
        uri: String,
        issuanceDate: String,
        image: String?,
        hasLocal: Bool,
        chainId: Int64?
    ) {
        self.contract = contract
        self.tokenId = tokenId
        self.name = name
        self.uri = uri
        self.issuanceDate = issuanceDate
        self.image = image
        self.hasLocal = hasLocal
        self.chainId = chainId
    }
}

/// 头像候选（字段与 Kotlin `AvatarCandidate` / `:did` port 的 `DidAvatarAsset` 完全一致；
/// Swift 合并为单类型，见 Nft-Swift 02 §2 合并决策）。
public struct DidAvatarAsset: Codable, Sendable, Equatable {
    public let image: String?
    public let name: String
    public let contract: String?
    public let tokenId: String
    public let issuer: String?
    public let tokenName: String?
    public let chainId: Int64?
    public let isSwtc: Bool

    public init(
        image: String?,
        name: String,
        contract: String?,
        tokenId: String,
        issuer: String?,
        tokenName: String?,
        chainId: Int64?,
        isSwtc: Bool
    ) {
        self.image = image
        self.name = name
        self.contract = contract
        self.tokenId = tokenId
        self.issuer = issuer
        self.tokenName = tokenName
        self.chainId = chainId
        self.isSwtc = isSwtc
    }
}

/// Kotlin 命名保真别名（非独立类型；`NftSdk.getAvatarCandidates` 在 Kotlin 返回 `AvatarCandidate`）。
public typealias AvatarCandidate = DidAvatarAsset

/// 元数据字段（仅 3 字段；`fetchMetadataFields` 失败返回 `.empty`，不 throw——对齐 Kotlin 非 Optional 签名）。
public struct NftMetadataFields: Codable, Sendable, Equatable {
    public var image: String?
    public var name: String?
    public var description: String?

    public init(image: String?, name: String?, description: String?) {
        self.image = image
        self.name = name
        self.description = description
    }

    public static let empty = NftMetadataFields(image: nil, name: nil, description: nil)
}

/// 图片解析请求（5 字段，镜像 Kotlin `CredentialImageRequest`）。
public struct CredentialImageRequest: Codable, Sendable, Equatable {
    public let imageUrl: String?
    public let metadataUri: String?
    public let chainId: Int64?
    public let contractAddress: String?
    public let tokenId: String?

    public init(
        imageUrl: String? = nil,
        metadataUri: String? = nil,
        chainId: Int64? = nil,
        contractAddress: String? = nil,
        tokenId: String? = nil
    ) {
        self.imageUrl = imageUrl
        self.metadataUri = metadataUri
        self.chainId = chainId
        self.contractAddress = contractAddress
        self.tokenId = tokenId
    }
}

/// 图片解析结果（`url` 非空；`cacheKey` 供宿主缓存图片，构造规则见 Nft-Swift 01 §4.4）。
public struct ResolvedCredentialImage: Codable, Sendable, Equatable {
    public let url: String
    public let cacheKey: String

    public init(url: String, cacheKey: String) {
        self.url = url
        self.cacheKey = cacheKey
    }
}

/// EVM `tokenURI(uint256)` 解析器（RPC 由宿主实现，模块不内置 eth_call；非 throw，失败返回 nil）。
public protocol IEthTokenUriResolver: Sendable {
    func resolveEthrTokenUri(contract: String, tokenId: String, chainId: Int64) async -> String?
}

/// `nft_meta` 持久化实体（对应 Kotlin `NftMetaEntity`；`fetchAndCacheNftMeta` 返回它）。
/// `id` 为自增主键（记录层），`(contract, tokenId)` 唯一。
public struct NftMeta: Codable, Sendable, Equatable {
    public var id: Int64?
    public let contract: String
    public let tokenId: String
    public let name: String?
    public let image: String?
    public let tokenUri: String?
    public let fullContent: String?
    public var updatedAt: Int64

    public init(
        id: Int64? = nil,
        contract: String,
        tokenId: String,
        name: String?,
        image: String?,
        tokenUri: String?,
        fullContent: String?,
        updatedAt: Int64
    ) {
        self.id = id
        self.contract = contract
        self.tokenId = tokenId
        self.name = name
        self.image = image
        self.tokenUri = tokenUri
        self.fullContent = fullContent
        self.updatedAt = updatedAt
    }
}

// MARK: - 持仓实体（对应 Kotlin storage/room/NftEntities.kt；字段逐一镜像）

/// `swtc_nfts` 表行。
public struct SwtcNftEntity: Codable, Sendable, Equatable {
    public let ownerAddress: String
    public let tokenId: String
    public let fundCode: String
    public let fundCodeName: String
    public let issuer: String
    public let tokenOwner: String
    public let tokenSender: String
    public let flags: String?
    public let tokenInfos: String?
    public let metadataUri: String?
    public let image: String?
    public let name: String?
    public let description: String?
    public let time: Int64
    public let hash: String?
    public let block: Int64
    public let inservice: Int
    public let ledgerIndex: String?
    public let lastUpdateTime: Int64

    public init(
        ownerAddress: String,
        tokenId: String,
        fundCode: String,
        fundCodeName: String,
        issuer: String,
        tokenOwner: String,
        tokenSender: String,
        flags: String? = nil,
        tokenInfos: String? = nil,
        metadataUri: String? = nil,
        image: String? = nil,
        name: String? = nil,
        description: String? = nil,
        time: Int64,
        hash: String? = nil,
        block: Int64,
        inservice: Int,
        ledgerIndex: String? = nil,
        lastUpdateTime: Int64 = Date.nowMillis()
    ) {
        self.ownerAddress = ownerAddress
        self.tokenId = tokenId
        self.fundCode = fundCode
        self.fundCodeName = fundCodeName
        self.issuer = issuer
        self.tokenOwner = tokenOwner
        self.tokenSender = tokenSender
        self.flags = flags
        self.tokenInfos = tokenInfos
        self.metadataUri = metadataUri
        self.image = image
        self.name = name
        self.description = description
        self.time = time
        self.hash = hash
        self.block = block
        self.inservice = inservice
        self.ledgerIndex = ledgerIndex
        self.lastUpdateTime = lastUpdateTime
    }
}

/// `evm_nft_items` 表行。
public struct EvmNftItemEntity: Codable, Sendable, Equatable {
    public let chainId: String
    public let ownerAddress: String
    public let contractAddress: String
    public let tokenId: String
    public let objectId: String?
    public let blockchainId: Int?
    public let ownerTimestamp: Int64?
    public let imageUrl: String?
    public let metadata: String?
    public let tokenProtocol: Int?
    public let title: String?
    public let description: String?
    public let updatedAt: Int64

    public init(
        chainId: String,
        ownerAddress: String,
        contractAddress: String,
        tokenId: String,
        objectId: String? = nil,
        blockchainId: Int? = nil,
        ownerTimestamp: Int64? = nil,
        imageUrl: String? = nil,
        metadata: String? = nil,
        tokenProtocol: Int? = nil,
        title: String? = nil,
        description: String? = nil,
        updatedAt: Int64 = Date.nowMillis()
    ) {
        self.chainId = chainId
        self.ownerAddress = ownerAddress
        self.contractAddress = contractAddress
        self.tokenId = tokenId
        self.objectId = objectId
        self.blockchainId = blockchainId
        self.ownerTimestamp = ownerTimestamp
        self.imageUrl = imageUrl
        self.metadata = metadata
        self.tokenProtocol = tokenProtocol
        self.title = title
        self.description = description
        self.updatedAt = updatedAt
    }
}

/// `evm_nft_collections` 表行。
public struct EvmNftCollectionEntity: Codable, Sendable, Equatable {
    public let chainId: String
    public let ownerAddress: String
    public let contractAddress: String
    public let name: String
    public let symbol: String
    public let iconUrl: String?
    public let decimals: Int
    public let hid: Int64?
    public let blockchainId: Int?
    public let tokenType: Int?
    public let tokenStatus: Int?
    public let tokenProtocol: Int
    public let ts: Int64?
    public let description: String?
    public let blSymbol: String?
    public let website: String?
    public let priceUsd: String?
    public let chg: String?
    public let validated: Int?
    public let gas: Int?
    public let liquidity: Double?
    public let priceUpdateTime: Int64?
    public let tokenCount: Int

    public init(
        chainId: String,
        ownerAddress: String,
        contractAddress: String,
        name: String,
        symbol: String,
        iconUrl: String? = nil,
        decimals: Int = 0,
        hid: Int64? = nil,
        blockchainId: Int? = nil,
        tokenType: Int? = nil,
        tokenStatus: Int? = nil,
        tokenProtocol: Int = 1,
        ts: Int64? = nil,
        description: String? = nil,
        blSymbol: String? = nil,
        website: String? = nil,
        priceUsd: String? = nil,
        chg: String? = nil,
        validated: Int? = nil,
        gas: Int? = nil,
        liquidity: Double? = nil,
        priceUpdateTime: Int64? = nil,
        tokenCount: Int = 0
    ) {
        self.chainId = chainId
        self.ownerAddress = ownerAddress
        self.contractAddress = contractAddress
        self.name = name
        self.symbol = symbol
        self.iconUrl = iconUrl
        self.decimals = decimals
        self.hid = hid
        self.blockchainId = blockchainId
        self.tokenType = tokenType
        self.tokenStatus = tokenStatus
        self.tokenProtocol = tokenProtocol
        self.ts = ts
        self.description = description
        self.blSymbol = blSymbol
        self.website = website
        self.priceUsd = priceUsd
        self.chg = chg
        self.validated = validated
        self.gas = gas
        self.liquidity = liquidity
        self.priceUpdateTime = priceUpdateTime
        self.tokenCount = tokenCount
    }
}
