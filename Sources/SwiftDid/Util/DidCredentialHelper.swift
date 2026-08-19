import Foundation
import SwiftNft

/// VC id 生成 / subject 构建 / 校验（对齐 Kotlin `DidCredentialHelper`，commit f77b59f）。
enum DidCredentialHelper {
    static let vcTypeOwnership = "NFTOwnership"
    static let vcTypeUsageAuthorization = "NFTUsageAuthorization"
    static let vcTypeFileAccessAuthorization = "FileAccessAuthorization"
    static let standardJingtumNFT = "jingtumNFT"
    static let standardERC721 = "ERC-721"
    static let contextTypeOwnership = "ownership"
    static let contextTypeUsageAuthorization = "usageAuthorization"

    static func isSwtcOwnerDid(_ ownerDid: String) -> Bool {
        ownerDid.hasPrefix("did:swtc:")
    }

    static func isEthrOwnerDid(_ ownerDid: String) -> Bool {
        ownerDid.hasPrefix("did:ethr:")
    }

    // MARK: - VC id（对齐 did_DApp generateVCId）

    static func generateVcId(_ data: UnifiedNftCredentialData) -> String {
        if self.isSwtcOwnerDid(data.ownerDid) {
            let tokenNameClean = (data.tokenName ?? "").replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            return "\(data.ownerDid)#nft-\(tokenNameClean)-\(data.nftIssuer ?? "")-\(data.tokenId)-\(data.granteeDid)"
        }
        let checksumContract = (try? ChecksumUtils.toChecksumAddress(data.contractAddress ?? "")) ?? ""
        return "\(data.ownerDid)#nft-\(checksumContract)-\(data.tokenId)-\(data.granteeDid)"
    }

    static func buildAvatarCredentialId(ownerDid: String, asset: DidAvatarAsset, granteeDid: String = "") -> String {
        let grantee = granteeDid.isEmpty ? ownerDid : granteeDid
        if asset.isSwtc {
            let tokenNameClean = (asset.tokenName ?? "").replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            return "\(ownerDid)#nft-\(tokenNameClean)-\(asset.issuer ?? "")-\(asset.tokenId)-\(grantee)"
        }
        let checksumContract = asset.contract.flatMap { try? ChecksumUtils.toChecksumAddress($0) } ?? ""
        return "\(ownerDid)#nft-\(checksumContract)-\(asset.tokenId)-\(grantee)"
    }

    // MARK: - 校验

    static func validateCredentialData(_ data: UnifiedNftCredentialData) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw CredentialDataError.invalid(message)
            }
        }
        try require(!data.granteeDid.isEmpty, "granteeDid is required")
        try require(!data.ownerDid.isEmpty, "ownerDid is required")
        try require(!data.tokenId.isEmpty, "tokenId is required")
        try require(!data.standard.isEmpty, "standard is required")
        try require(!data.status.isEmpty, "status is required")
        try require(data.chainId > 0, "chainId must be positive")
        if self.isEthrOwnerDid(data.ownerDid) {
            try require(!self.isBlank(data.contractAddress), "contractAddress is required for EVM owner DID")
        }
        if self.isSwtcOwnerDid(data.ownerDid) {
            try require(!self.isBlank(data.nftIssuer), "nftIssuer is required for SWTC owner DID")
            try require(!self.isBlank(data.tokenName), "tokenName is required for SWTC owner DID")
        }
        if data.type == .others {
            try require(data.usageRights?.isEmpty == false, "usageRights is required for OTHERS authorization")
            try require(data.restrictions != nil, "restrictions is required for OTHERS authorization")
        }
    }

    enum CredentialDataError: Error, Equatable {
        case invalid(String)
    }

    // MARK: - subject / types / context

    static func buildNftSubject(_ data: UnifiedNftCredentialData) -> [String: Any] {
        var subject: [String: Any] = [
            "id": data.granteeDid,
            "owner": data.ownerDid,
            "chainId": data.chainId,
            "tokenId": data.tokenId,
            "status": data.status,
            "standard": data.standard
        ]
        if self.isSwtcOwnerDid(data.ownerDid) {
            subject["nftIssuer"] = data.nftIssuer ?? ""
            subject["tokenName"] = data.tokenName ?? ""
        } else {
            subject["contractAddress"] = (try? ChecksumUtils.toChecksumAddress(data.contractAddress ?? "")) ?? ""
        }
        if data.type == .others {
            subject["usageRights"] = self.usageRightsToJson(data.usageRights ?? [])
            if let restrictions = data.restrictions {
                subject["restrictions"] = self.restrictionsToJson(restrictions)
            }
        }
        return subject
    }

    static func vcTypesFor(_ data: UnifiedNftCredentialData) -> [String] {
        data.type == .selfOwned
            ? ["VerifiableCredential", self.vcTypeOwnership]
            : ["VerifiableCredential", self.vcTypeUsageAuthorization]
    }

    static func contextTypeFor(_ data: UnifiedNftCredentialData) -> String {
        data.type == .selfOwned ? self.contextTypeOwnership : self.contextTypeUsageAuthorization
    }

    static func credentialIncludesType(_ credentialJson: String, _ type: String) -> Bool {
        guard let object = DidJson.parseObject(credentialJson),
              let types = DidJson.optArray(object, "type")
        else { return false }
        return types.contains { ($0 as? String)?.caseInsensitiveCompare(type) == .orderedSame }
    }

    // MARK: - 解析

    static func ownerDidFromCredentialId(_ credentialId: String) -> String {
        for separator in ["#nft", "#file-access", "#phone"] {
            if credentialId.contains(separator) {
                return String(credentialId.split(separator: "#", maxSplits: 1)[0])
            }
        }
        return ""
    }

    static func readCredentials(_ doc: String) -> [Any] {
        guard let object = DidJson.parseObject(doc) else { return [] }
        return DidJson.optArray(object, "credentials") ?? DidJson.optArray(object, "credential") ?? []
    }

    static func findCredentialIndex(_ credentials: [Any], _ credentialId: String) -> Int {
        credentials.firstIndex { credential -> Bool in
            guard let object = credential as? [String: Any] else { return false }
            return DidJson.optString(object, "id").caseInsensitiveCompare(credentialId) == .orderedSame
        } ?? -1
    }

    static func clearPreferredAvatarIfMatches(_ services: [Any], _ credentialId: String) -> [Any] {
        services.map { service -> Any in
            guard var serviceObject = service as? [String: Any],
                  DidJson.optString(serviceObject, "type") == "Profile",
                  var endpoint = DidJson.optDict(serviceObject, "serviceEndpoint"),
                  DidJson.optString(endpoint, "preferredAvatar").caseInsensitiveCompare(credentialId) == .orderedSame
            else { return service }
            endpoint["preferredAvatar"] = ""
            serviceObject["serviceEndpoint"] = endpoint
            return serviceObject
        }
    }

    static func fromAvatarCredential(ownerDid: String, avatar: DidAvatarCredential) -> UnifiedNftCredentialData {
        if avatar.isSwtc {
            return UnifiedNftCredentialData(
                type: .selfOwned,
                granteeDid: ownerDid,
                ownerDid: ownerDid,
                chainId: 315,
                tokenId: avatar.tokenId,
                standard: self.standardJingtumNFT,
                nftIssuer: avatar.issuer,
                tokenName: avatar.tokenName
            )
        }
        return UnifiedNftCredentialData(
            type: .selfOwned,
            granteeDid: ownerDid,
            ownerDid: ownerDid,
            chainId: avatar.chainId ?? 1,
            tokenId: avatar.tokenId,
            standard: self.standardERC721,
            contractAddress: avatar.contract
        )
    }

    // MARK: - JSON 序列化

    static func usageRightsToJson(_ values: [UsageRights]) -> [Any] {
        values.map(\.rawValue)
    }

    static func restrictionsToJson(_ restrictions: NftCredentialRestrictions) -> [String: Any] {
        [
            "commercial": restrictions.commercial,
            "derivative": restrictions.derivative,
            "sublicense": restrictions.sublicense,
            "territories": restrictions.territories,
            "platforms": restrictions.platforms
        ]
    }

    private static func isBlank(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
