import Foundation

// MARK: - NFT 凭证（VC）模型（镜像 Kotlin :did model/CredentialModels.kt，commit f77b59f）

public enum CredentialAuthorizationType: String, Codable, Sendable, Equatable {
    case selfOwned = "SELF"
    case others = "OTHERS"
}

public enum UsageRights: String, Codable, Sendable, Equatable, CaseIterable {
    case avatar
    case nonCommercialDisplay = "non-commercial-display"

    public static func fromValue(_ value: String) -> UsageRights? {
        allCases.first { $0.rawValue == value }
    }
}

public struct NftCredentialRestrictions: Codable, Sendable, Equatable {
    public var commercial: Bool
    public var derivative: Bool
    public var sublicense: Bool
    public var territories: [String]
    public var platforms: [String]

    public init(
        commercial: Bool = false,
        derivative: Bool = false,
        sublicense: Bool = false,
        territories: [String] = [],
        platforms: [String] = []
    ) {
        self.commercial = commercial
        self.derivative = derivative
        self.sublicense = sublicense
        self.territories = territories
        self.platforms = platforms
    }
}

/// 对齐 did_DApp `UnifiedNFTCredentialData`。
public struct UnifiedNftCredentialData: Codable, Sendable, Equatable {
    public let type: CredentialAuthorizationType
    public let granteeDid: String
    public let ownerDid: String
    public let chainId: Int64
    public let tokenId: String
    public let standard: String
    public var status: String
    public let contractAddress: String?
    public let nftIssuer: String?
    public let tokenName: String?
    public let usageRights: [UsageRights]?
    public let restrictions: NftCredentialRestrictions?
    public var expirationDurationMs: Int64

    public init(
        type: CredentialAuthorizationType,
        granteeDid: String,
        ownerDid: String,
        chainId: Int64,
        tokenId: String,
        standard: String,
        status: String = "Active",
        contractAddress: String? = nil,
        nftIssuer: String? = nil,
        tokenName: String? = nil,
        usageRights: [UsageRights]? = nil,
        restrictions: NftCredentialRestrictions? = nil,
        expirationDurationMs: Int64 = 365 * 24 * 60 * 60 * 1000
    ) {
        self.type = type
        self.granteeDid = granteeDid
        self.ownerDid = ownerDid
        self.chainId = chainId
        self.tokenId = tokenId
        self.standard = standard
        self.status = status
        self.contractAddress = contractAddress
        self.nftIssuer = nftIssuer
        self.tokenName = tokenName
        self.usageRights = usageRights
        self.restrictions = restrictions
        self.expirationDurationMs = expirationDurationMs
    }
}

/// 验签结果（Swift 增强：保留 `errorKind`/`error`——Kotlin 丢弃了这两个字段，见 Did-Swift 04 坑 #21）。
public struct CredentialVerificationResult: Codable, Sendable, Equatable {
    public let verified: Bool
    public let results: String?
    public let errorKind: String?
    public let error: String?

    public init(verified: Bool, results: String? = nil, errorKind: String? = nil, error: String? = nil) {
        self.verified = verified
        self.results = results
        self.errorKind = errorKind
        self.error = error
    }
}

public struct GranteeCredentialUpdateResult: Codable, Sendable, Equatable {
    public let isUpdate: Bool
    public let credential: String?
    /// 为 true 时表示因 owner DID 文档拉取失败（网络/解析）而无法判定 `isUpdate`——
    /// 调用方不应把瞬时失败当成「已被撤销/替换」。
    public let fetchFailed: Bool

    public init(isUpdate: Bool, credential: String? = nil, fetchFailed: Bool = false) {
        self.isUpdate = isUpdate
        self.credential = credential
        self.fetchFailed = fetchFailed
    }
}

public struct QueryVcidResult: Codable, Sendable, Equatable {
    public let isValid: Bool
    public let credential: String?

    public init(isValid: Bool, credential: String? = nil) {
        self.isValid = isValid
        self.credential = credential
    }
}
