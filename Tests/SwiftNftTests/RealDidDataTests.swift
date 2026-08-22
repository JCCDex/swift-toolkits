import GRDB
import SwiftDappConnect
@testable import SwiftNft
import XCTest

/// 真实数据回归测试：mock 数据取自两个示例 DID 的实际链上返回（2026-08-19 提取，
/// fixtures 见 `Tests/SwiftNftTests/Fixtures/`）：
/// - `did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq`：SWTC ownership VC（NFTOwnership /
///   jingtumNFT / issuer `j9pmAC…` / tokenId `43726F…08`）+ 真实元数据（CCDAO NFT #8，
///   image `ipfs://bafybei…/8.png`）；
/// - `did:ethr:0xa4FdA51E902Ba5f6b6322DEe039be7678Ba4584F` 文档携带的 ERC-721 usage VC
///   （`0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a` / tokenId `4` / chainId 1）+ 真实
///   元数据（CCDAO NFT #4）。
/// 断言锚点均为库中真实值（issuer / tokenId / metadataUri / 图片 CID），非虚构。
final class RealDidDataTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBNftStore!
    private var databaseURL: URL!
    private var http: FakeNftHttpClient!
    private var swtc: FakeSwtcTokenUriResolver!
    private var resolver: FakeEthTokenUriResolver!
    private var sdk: NftClient!

    private let gateway = "https://ipfs.jccdex.cn/ipfs/"

    // 真实值（fixtures 与断言共用）
    private let swtcIssuer = "j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc"
    private let swtcTokenId = "43726F737320436861696E2044414F2000000000000000000000000000000008"
    private let swtcMetadataUri = "ipfs://bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8"
    private let swtcImageCid = "bafybeiequepagic2llma3wv22n3rjwloi35pvc65luyesayx6eb2r3dftu/8.png"
    private let ethrContract = "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a"
    private let ethrMetadataUri = "ipfs://bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/4"
    private let ethrImageCid = "bafybeiequepagic2llma3wv22n3rjwloi35pvc65luyesayx6eb2r3dftu/4.png"

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("nft-real-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBNftStore(database: self.database)
        self.http = FakeNftHttpClient()
        self.swtc = FakeSwtcTokenUriResolver()
        self.resolver = FakeEthTokenUriResolver()
        self.sdk = NftClient(config: SwiftNftConfig(
            store: self.store,
            httpClient: self.http,
            ethTokenUriResolver: self.resolver,
            swtcTokenUriResolver: self.swtc
        ))
        SsrfGuard.enabled = false
    }

    override func tearDown() {
        SsrfGuard.enabled = true
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        self.database = nil
        self.store = nil
        self.http = nil
        self.swtc = nil
        self.resolver = nil
        self.sdk = nil
    }

    // MARK: - 真实 DID 头像解析链

    /// did:swtc 头像：SWTC ownership VC → erc_info（真实 metadataUri）→ 真实元数据 → 网关图片 URL。
    func testResolveSwtcAvatarWithRealDidData() async throws {
        self.swtc.setResult(self.swtcMetadataUri, for: self.swtcTokenId)
        self.http.enqueueJson(self.nft8Metadata, for: self.gateway + "bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8")

        let nft = await self.sdk.resolveSwtcAvatar(vc: self.swtcOwnershipVC)

        XCTAssertEqual(nft?.name, "CCDAO NFT #8")
        XCTAssertEqual(nft?.image, "\(self.gateway)\(self.swtcImageCid)")
        XCTAssertEqual(nft?.hasLocal, true)
        XCTAssertEqual(nft?.uri, self.gateway + "bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8")
        XCTAssertEqual(self.swtc.requested, [self.swtcTokenId])
        // 元数据已落 nft_meta（fetchAndCacheNftMeta 预取）
        let meta = try await self.store.nftMeta(contract: self.swtcIssuer, tokenId: self.swtcTokenId)
        XCTAssertEqual(meta?.name, "CCDAO NFT #8")
        XCTAssertEqual(meta?.tokenUri, self.swtcMetadataUri)
    }

    /// did:ethr 头像（ERC-721 usage VC）：resolver（真实 tokenURI）→ 真实元数据 → 网关图片 URL。
    /// 与 Kotlin 分支语义一致：无 evm_nft_items / nft_meta 时第一轮只拿到 resolver 的 tokenURI
    /// （name/image 为空）；`fetchAndCacheNftMeta` 预取（generateProfileVC 的前置步骤）后，
    /// 第二轮 nft_meta 命中 → 出图，且本地 tokenUri 非空不再调 resolver（惰性 eth_call）。
    func testResolveEthrAvatarWithRealDidData() async {
        let tokenUri = self.gateway + "bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/4"
        self.resolver.setResult(self.ethrMetadataUri)
        // resolveRemoteImageURL 对元数据走 fetchText（提图）；fetchAndCacheNftMeta 走 fetchJson（落库）
        self.http.enqueueText(self.nft4Metadata, for: tokenUri)

        // 第一轮：无 evm item → 仅 resolver tokenURI；image 由 resolveRemoteImageURL 拉元数据提图
        let nft = await self.sdk.resolveEthrAvatar(vc: self.ethrErc721VC)
        XCTAssertEqual(nft?.name, "")
        XCTAssertEqual(nft?.uri, tokenUri)
        XCTAssertEqual(nft?.image, "\(self.gateway)\(self.ethrImageCid)")
        XCTAssertEqual(nft?.hasLocal, false)
        XCTAssertEqual(nft?.chainId, 1)
        XCTAssertEqual(nft?.contract, self.ethrContract)
        XCTAssertEqual(nft?.tokenId, "4")
        XCTAssertEqual(self.resolver.callCount, 1)
        XCTAssertEqual(self.resolver.lastContract, self.ethrContract)
        XCTAssertEqual(self.resolver.lastTokenId, "4")
        XCTAssertEqual(self.resolver.lastChainId, 1)

        // 预取元数据（generateProfileVC 前置）后第二轮：nft_meta 命中出图，不调 resolver
        self.http.enqueueJson(self.nft4Metadata, for: tokenUri)
        _ = await self.sdk.fetchAndCacheNftMeta(contract: self.ethrContract, tokenId: "4", tokenUri: nft?.uri ?? "")
        let nft2 = await self.sdk.resolveEthrAvatar(vc: self.ethrErc721VC)
        XCTAssertEqual(nft2?.name, "CCDAO NFT #4")
        XCTAssertEqual(nft2?.image, "\(self.gateway)\(self.ethrImageCid)")
        XCTAssertEqual(nft2?.hasLocal, true)
        XCTAssertEqual(self.resolver.callCount, 1, "nft_meta 命中且本地 tokenUri 非空 → 不再调 resolver")
    }

    // MARK: - 真实元数据字段提取

    func testFetchMetadataFieldsWithRealMetadata() async {
        // fetchMetadataFields 走 fetchText：真实 #8 元数据 body 在真实网关 URL 下返回
        self.http.enqueueText(self.nft8Metadata, for: self.gateway + "bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8")
        let fields = await self.sdk.fetchMetadataFields(self.swtcMetadataUri)
        XCTAssertEqual(fields.name, "CCDAO NFT #8")
        XCTAssertEqual(fields.image, "\(self.gateway)\(self.swtcImageCid)")
    }

    // MARK: - 真实图片 URL 解析

    func testResolveCredentialImageWithRealIpfsImage() async {
        // 真实 ipfs 图片 → 默认网关（直出，无网络）
        let resolved = await self.sdk.resolveCredentialImage(
            "ipfs://\(self.swtcImageCid)",
            metadataUri: self.swtcMetadataUri
        )
        XCTAssertEqual(resolved, "\(self.gateway)\(self.swtcImageCid)")
    }

    func testResolveCredentialImagesWithRealRequests() async {
        // 两个真实请求（#8 元数据直出图片、#4 经元数据提图）→ 各自网关 URL
        // resolveCredentialImage(nil, metadataUri:) 对元数据走 fetchText（见 fetchResolvedMetadataImage）
        self.http.enqueueText(self.nft4Metadata, for: self.gateway + "bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/4")
        let requests = [
            CredentialImageRequest(imageUrl: "ipfs://\(self.swtcImageCid)", metadataUri: self.swtcMetadataUri),
            CredentialImageRequest(imageUrl: nil, metadataUri: self.ethrMetadataUri)
        ]
        let results = await self.sdk.resolveCredentialImages(requests)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0]?.url, "\(self.gateway)\(self.swtcImageCid)")
        XCTAssertEqual(results[1]?.url, "\(self.gateway)\(self.ethrImageCid)")
    }

    // MARK: - 真实 erc_info 响应形状（hex InfoType/InfoData，来自链上实际返回结构）

    func testExtractSwtcMetadataUriWithRealErcInfoShape() {
        // InfoType == "tokenUri"（hex），InfoData == 真实 metadataUri（hex）
        let infoTypeHex = Self.hex("tokenUri")
        let infoDataHex = Self.hex(self.swtcMetadataUri)
        let payload = """
        [{"TokenInfo":{"InfoType":"\(infoTypeHex)","InfoData":"\(infoDataHex)"}}]
        """
        XCTAssertEqual(
            self.sdk.extractSwtcMetadataUri(payload),
            self.gateway + "bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8"
        )
    }

    func testExtractSwtcMetadataUriIgnoresNonTokenUriInfoTypes() {
        let payload = """
        [{"TokenInfo":{"InfoType":"\(Self.hex("name"))","InfoData":"\(Self.hex("CCDAO NFT #8"))"}},
         {"TokenInfo":{"InfoType":"\(Self.hex("tokenUri"))","InfoData":"\(Self.hex(self.swtcMetadataUri))"}}]
        """
        XCTAssertEqual(
            self.sdk.extractSwtcMetadataUri(payload),
            self.gateway + "bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8",
            "非 tokenUri 项跳过，只认 InfoType == tokenUri"
        )
    }

    // MARK: - Fixtures

    private var swtcOwnershipVC: String {
        self.fixture("swtc_ownership_vc")
    }

    private var ethrErc721VC: String {
        self.fixture("ethr_erc721_vc")
    }

    private var nft8Metadata: String {
        self.fixture("nft8_metadata")
    }

    private var nft4Metadata: String {
        self.fixture("nft4_metadata")
    }

    private func fixture(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            XCTFail("fixture 缺失: \(name).json（.copy(\"Fixtures\") 保留目录层级，需 subdirectory 参数）")
            return ""
        }
        return content
    }

    private static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
