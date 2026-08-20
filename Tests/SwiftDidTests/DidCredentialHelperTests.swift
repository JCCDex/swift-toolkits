import SwiftDappConnect
@testable import SwiftDid
import SwiftNft
import XCTest

/// DidCredentialHelper 单测：VC id 生成、subject/类型/context 构建、数据校验、
/// 文档解析辅助。真实值断言锚点取自示例 DID 的实际 VC（fixtures，见 Fixtures/）：
/// swtc ownership VC id 形如 `did:swtc:jwWmui…Rq#nft-CrossChainDAONFT-j9pmAC…-43726F…08-did:swtc:jwWmui…Rq`。
final class DidCredentialHelperTests: XCTestCase {
    private let swtcOwnerDid = "did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq"
    private let ethrOwnerDid = "did:ethr:0x12898725Cf301693733D951bb992C30310dBfb3B"

    // MARK: - owner DID 判定

    func testOwnerDidPrefixes() {
        XCTAssertTrue(DidCredentialHelper.isSwtcOwnerDid(self.swtcOwnerDid))
        XCTAssertFalse(DidCredentialHelper.isSwtcOwnerDid(self.ethrOwnerDid))
        XCTAssertTrue(DidCredentialHelper.isEthrOwnerDid(self.ethrOwnerDid))
        XCTAssertFalse(DidCredentialHelper.isEthrOwnerDid("did:swtc:x"))
    }

    // MARK: - VC id 生成（对齐真实 VC id 形态）

    func testGenerateVcIdForSwtcOwner() {
        // 真实形态：ownerDid#nft-<tokenName 去空白>-<issuer>-<tokenId>-<grantee>
        let data = UnifiedNftCredentialData(
            type: .selfOwned,
            granteeDid: self.swtcOwnerDid,
            ownerDid: self.swtcOwnerDid,
            chainId: 315,
            tokenId: "43726F737320436861696E2044414F2000000000000000000000000000000008",
            standard: "jingtumNFT",
            nftIssuer: "j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc",
            tokenName: "Cross Chain DAO NFT"
        )
        let vcId = DidCredentialHelper.generateVcId(data)
        XCTAssertEqual(
            vcId,
            "\(self.swtcOwnerDid)#nft-CrossChainDAONFT-j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc-43726F737320436861696E2044414F2000000000000000000000000000000008-\(self.swtcOwnerDid)"
        )
    }

    func testGenerateVcIdForEthrOwnerChecksumsContract() {
        let data = UnifiedNftCredentialData(
            type: .selfOwned,
            granteeDid: self.ethrOwnerDid,
            ownerDid: self.ethrOwnerDid,
            chainId: 1,
            tokenId: "4",
            standard: "ERC-721",
            contractAddress: "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a"
        )
        let vcId = DidCredentialHelper.generateVcId(data)
        XCTAssertTrue(vcId.hasPrefix("\(self.ethrOwnerDid)#nft-0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a-4-"))
    }

    func testBuildAvatarCredentialId() {
        let swtcAsset = DidAvatarAsset(
            image: nil, name: "Cross Chain DAO NFT", contract: nil, tokenId: "1",
            issuer: "j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc", tokenName: "Cross Chain DAO NFT",
            chainId: nil, isSwtc: true
        )
        XCTAssertEqual(
            DidCredentialHelper.buildAvatarCredentialId(ownerDid: self.swtcOwnerDid, asset: swtcAsset, granteeDid: "did:swtc:g"),
            "\(self.swtcOwnerDid)#nft-CrossChainDAONFT-j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc-1-did:swtc:g"
        )

        let ethrAsset = DidAvatarAsset(
            image: nil, name: "", contract: "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a", tokenId: "4",
            issuer: nil, tokenName: nil, chainId: 1, isSwtc: false
        )
        XCTAssertTrue(
            DidCredentialHelper.buildAvatarCredentialId(ownerDid: self.ethrOwnerDid, asset: ethrAsset)
                .hasPrefix("\(self.ethrOwnerDid)#nft-0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a-4-")
        )
    }

    // MARK: - 数据校验

    func testValidateCredentialDataRequiresBaseFields() {
        func data(
            grantee: String = "g", owner: String = self.swtcOwnerDid, chainId: Int64 = 315,
            tokenId: String = "1", standard: String = "jingtumNFT", status: String = "Active",
            nftIssuer: String = "issuer", tokenName: String = "Name"
        ) -> UnifiedNftCredentialData {
            UnifiedNftCredentialData(
                type: .selfOwned, granteeDid: grantee, ownerDid: owner, chainId: chainId,
                tokenId: tokenId, standard: standard, status: status,
                nftIssuer: nftIssuer, tokenName: tokenName
            )
        }
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(grantee: "")))
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(owner: "")))
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(tokenId: "")))
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(standard: "")))
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(status: "")))
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(chainId: 0)))
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(nftIssuer: "")), "SWTC owner 必须 nftIssuer")
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(data(tokenName: "")), "SWTC owner 必须 tokenName")
        // 合法数据不抛
        XCTAssertNoThrow(try DidCredentialHelper.validateCredentialData(data()))
    }

    func testValidateCredentialDataRequiresContractForEthrOwner() {
        let ethr = UnifiedNftCredentialData(
            type: .selfOwned, granteeDid: "g", ownerDid: self.ethrOwnerDid, chainId: 1,
            tokenId: "4", standard: "ERC-721", contractAddress: nil
        )
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(ethr), "EVM owner 必须 contractAddress")
        var valid = ethr
        valid = UnifiedNftCredentialData(
            type: .selfOwned, granteeDid: "g", ownerDid: self.ethrOwnerDid, chainId: 1,
            tokenId: "4", standard: "ERC-721", contractAddress: "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a"
        )
        XCTAssertNoThrow(try DidCredentialHelper.validateCredentialData(valid))
    }

    func testValidateCredentialDataRequiresUsageRightsForOthers() {
        let others = UnifiedNftCredentialData(
            type: .others, granteeDid: "g", ownerDid: self.swtcOwnerDid, chainId: 315,
            tokenId: "1", standard: "jingtumNFT", nftIssuer: "issuer", tokenName: "Name",
            usageRights: nil, restrictions: nil
        )
        XCTAssertThrowsError(try DidCredentialHelper.validateCredentialData(others), "OTHERS 必须 usageRights + restrictions")
        var valid = others
        valid = UnifiedNftCredentialData(
            type: .others, granteeDid: "g", ownerDid: self.swtcOwnerDid, chainId: 315,
            tokenId: "1", standard: "jingtumNFT", nftIssuer: "issuer", tokenName: "Name",
            usageRights: [.avatar], restrictions: NftCredentialRestrictions()
        )
        XCTAssertNoThrow(try DidCredentialHelper.validateCredentialData(valid))
    }

    // MARK: - subject / types / context

    func testBuildNftSubjectForSwtcOwner() {
        let data = UnifiedNftCredentialData(
            type: .selfOwned, granteeDid: "g", ownerDid: self.swtcOwnerDid, chainId: 315,
            tokenId: "1", standard: "jingtumNFT", nftIssuer: "issuer", tokenName: "Name"
        )
        let subject = DidCredentialHelper.buildNftSubject(data)
        XCTAssertEqual(subject["id"] as? String, "g")
        XCTAssertEqual(subject["owner"] as? String, self.swtcOwnerDid)
        XCTAssertEqual(subject["chainId"] as? Int64, 315)
        XCTAssertEqual(subject["nftIssuer"] as? String, "issuer")
        XCTAssertEqual(subject["tokenName"] as? String, "Name")
        XCTAssertNil(subject["contractAddress"])
    }

    func testBuildNftSubjectForEthrOwnerChecksumsContract() {
        let data = UnifiedNftCredentialData(
            type: .selfOwned, granteeDid: "g", ownerDid: self.ethrOwnerDid, chainId: 1,
            tokenId: "4", standard: "ERC-721", contractAddress: "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a"
        )
        let subject = DidCredentialHelper.buildNftSubject(data)
        XCTAssertEqual(subject["contractAddress"] as? String, "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a")
        XCTAssertNil(subject["nftIssuer"])
    }

    func testBuildNftSubjectForOthersIncludesUsageAndRestrictions() {
        let data = UnifiedNftCredentialData(
            type: .others, granteeDid: "g", ownerDid: self.swtcOwnerDid, chainId: 315,
            tokenId: "1", standard: "jingtumNFT", nftIssuer: "issuer", tokenName: "Name",
            usageRights: [.avatar, .nonCommercialDisplay],
            restrictions: NftCredentialRestrictions(commercial: true, territories: ["CN"], platforms: ["JCCDex"])
        )
        let subject = DidCredentialHelper.buildNftSubject(data)
        XCTAssertEqual(subject["usageRights"] as? [String], ["avatar", "non-commercial-display"])
        let restrictions = subject["restrictions"] as? [String: Any]
        XCTAssertEqual(restrictions?["commercial"] as? Bool, true)
        XCTAssertEqual(restrictions?["territories"] as? [String], ["CN"])
        XCTAssertEqual(restrictions?["platforms"] as? [String], ["JCCDex"])
    }

    func testVcTypesAndContext() {
        let selfOwned = UnifiedNftCredentialData(
            type: .selfOwned, granteeDid: "g", ownerDid: self.swtcOwnerDid, chainId: 315,
            tokenId: "1", standard: "jingtumNFT"
        )
        XCTAssertEqual(DidCredentialHelper.vcTypesFor(selfOwned), ["VerifiableCredential", "NFTOwnership"])
        XCTAssertEqual(DidCredentialHelper.contextTypeFor(selfOwned), "ownership")

        let others = UnifiedNftCredentialData(
            type: .others, granteeDid: "g", ownerDid: self.swtcOwnerDid, chainId: 315,
            tokenId: "1", standard: "jingtumNFT"
        )
        XCTAssertEqual(DidCredentialHelper.vcTypesFor(others), ["VerifiableCredential", "NFTUsageAuthorization"])
        XCTAssertEqual(DidCredentialHelper.contextTypeFor(others), "usageAuthorization")
    }

    // MARK: - 解析辅助（真实 fixture）

    func testCredentialIncludesTypeWithRealVc() {
        XCTAssertTrue(DidCredentialHelper.credentialIncludesType(self.fixture("swtc_ownership_vc"), "NFTOwnership"))
        XCTAssertFalse(DidCredentialHelper.credentialIncludesType(self.fixture("swtc_ownership_vc"), "NFTUsageAuthorization"))
        XCTAssertFalse(DidCredentialHelper.credentialIncludesType("not json", "NFTOwnership"))
    }

    func testOwnerDidFromCredentialIdWithRealId() {
        let realId = "did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq#nft-CrossChainDAONFT-j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc-43726F737320436861696E2044414F2000000000000000000000000000000008-did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq"
        XCTAssertEqual(DidCredentialHelper.ownerDidFromCredentialId(realId), self.swtcOwnerDid)
        XCTAssertEqual(DidCredentialHelper.ownerDidFromCredentialId("did:swtc:x#file-access-knowledge"), "did:swtc:x")
        XCTAssertEqual(DidCredentialHelper.ownerDidFromCredentialId("no-separator"), "")
    }

    func testReadCredentialsAndFindIndexWithRealDoc() {
        let doc = self.fixture("did_swtc")
        let credentials = DidCredentialHelper.readCredentials(doc)
        XCTAssertEqual(credentials.count, 9)
        let targetId = "\(self.swtcOwnerDid)#nft-CrossChainDAONFT-j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc-43726F737320436861696E2044414F2000000000000000000000000000000008-\(self.swtcOwnerDid)"
        XCTAssertEqual(DidCredentialHelper.findCredentialIndex(credentials, targetId), 0)
        XCTAssertEqual(DidCredentialHelper.findCredentialIndex(credentials, "missing"), -1)
    }

    func testClearPreferredAvatarIfMatches() {
        let services: [Any] = [
            ["type": "Profile", "serviceEndpoint": ["nickname": "a", "preferredAvatar": "vc-1"]],
            ["type": "IpfsStorage", "serviceEndpoint": ["cid": "x"]]
        ]
        let cleared = DidCredentialHelper.clearPreferredAvatarIfMatches(services, "vc-1")
        let profile = cleared[0] as? [String: Any]
        let endpoint = profile?["serviceEndpoint"] as? [String: Any]
        XCTAssertEqual(endpoint?["preferredAvatar"] as? String, "")
        // 不匹配的保留原样
        let untouched = DidCredentialHelper.clearPreferredAvatarIfMatches(services, "vc-2")
        let endpoint2 = (untouched[0] as? [String: Any])?["serviceEndpoint"] as? [String: Any]
        XCTAssertEqual(endpoint2?["preferredAvatar"] as? String, "vc-1")
    }

    func testFromAvatarCredential() {
        let swtc = DidAvatarCredential(
            credentialId: "id", image: nil, name: "Cross Chain DAO NFT", contract: "j9pmAC", tokenId: "1",
            issuer: "j9pmAC", tokenName: "Cross Chain DAO NFT", chainId: nil, isSwtc: true,
            ownerDid: self.swtcOwnerDid
        )
        let swtcData = DidCredentialHelper.fromAvatarCredential(ownerDid: self.swtcOwnerDid, avatar: swtc)
        XCTAssertEqual(swtcData.standard, "jingtumNFT")
        XCTAssertEqual(swtcData.chainId, 315)
        XCTAssertEqual(swtcData.nftIssuer, "j9pmAC")

        let ethr = DidAvatarCredential(
            credentialId: "id", image: nil, name: "", contract: "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a",
            tokenId: "4", issuer: nil, tokenName: nil, chainId: 1, isSwtc: false,
            ownerDid: self.ethrOwnerDid
        )
        let ethrData = DidCredentialHelper.fromAvatarCredential(ownerDid: self.ethrOwnerDid, avatar: ethr)
        XCTAssertEqual(ethrData.standard, "ERC-721")
        XCTAssertEqual(ethrData.chainId, 1)
        XCTAssertEqual(ethrData.contractAddress, "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a")
    }

    // MARK: - Fixtures

    private func fixture(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            XCTFail("fixture 缺失: \(name).json")
            return ""
        }
        return content
    }
}
