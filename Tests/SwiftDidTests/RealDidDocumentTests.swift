import GRDB
import SwiftCore
import SwiftDappConnect
@testable import SwiftDid
import SwiftNft
import XCTest

/// 真实数据回归测试（SwiftDid 门面）：mock 数据取自两个示例 DID 的实际文档
/// （2026-08-19 提取，fixtures 见 `Tests/SwiftDidTests/Fixtures/`）：
/// - `did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq`：Profile nickname "swtc"、
///   preferredAvatar 指向 ERC-721 usage VC（0x5B5b…/4，chainId 1）、9 个 credentials；
/// - `did:ethr:0xa4FdA51E902Ba5f6b6322DEe039be7678Ba4584F`：Profile nickname "eth-did"、
///   preferredAvatar 指向 SWTC ownership VC（issuer j9pmAC…/tokenId 43726F…）、1 个 credential。
@MainActor
final class RealDidDocumentTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBDidStore!
    private var bridge: FakeDidBridge!
    private var databaseURL: URL!
    private var did: SwiftDid!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("did-real-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBDidStore(database: self.database)
        self.bridge = FakeDidBridge()
        self.did = SwiftDid(store: self.store, bridge: self.bridge)
    }

    override func tearDown() {
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        self.database = nil
        self.store = nil
        self.bridge = nil
        self.did = nil
    }

    // MARK: - 真实文档解析（本地，不依赖桥）

    func testGenerateDidFromRealSwtcDocument() async throws {
        let didStr = "did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq"
        try await self.store.save(DidEntity(did: didStr, doc: self.fixture("did_swtc"), updatedAt: 1))
        let model = await self.did.generateDid(didStr)
        XCTAssertEqual(model?.id, didStr)
        XCTAssertEqual(model?.created, "2026-07-02 09:56:24", "Asia/Shanghai 时区换算")
        XCTAssertEqual(model?.updated, "2026-08-12 14:45:37")
        XCTAssertEqual(model?.verificationMethods.count, 1)
        XCTAssertEqual(model?.verificationMethods.first?.type, "EcdsaSecp256k1VerificationKey2019", "真实文档用 ECDSA 密钥")
        XCTAssertTrue(model?.verificationMethods.first?.isSelf == true)
    }

    func testGenerateDidFromRealEthrDocument() async throws {
        let didStr = "did:ethr:0xa4FdA51E902Ba5f6b6322DEe039be7678Ba4584F"
        try await self.store.save(DidEntity(did: didStr, doc: self.fixture("did_ethr"), updatedAt: 1))
        let model = await self.did.generateDid(didStr)
        XCTAssertEqual(model?.id, didStr)
        XCTAssertEqual(model?.created, "2026-07-14 14:05:13")
        XCTAssertEqual(model?.updated, "2026-07-14 15:22:31")
        XCTAssertEqual(model?.verificationMethods.count, 1)
    }

    func testReadCredentialsFromRealDocuments() async throws {
        try await self.store.save(DidEntity(did: "d1", doc: self.fixture("did_swtc"), updatedAt: 1))
        try await self.store.save(DidEntity(did: "d2", doc: self.fixture("did_ethr"), updatedAt: 1))
        XCTAssertEqual(self.did.readCredentials(self.fixture("did_swtc")).count, 9)
        XCTAssertEqual(self.did.readCredentials(self.fixture("did_ethr")).count, 1)
    }

    func testGenerateProfileVCRealSwtcPrefersEthAvatarVc() async throws {
        // swtc 文档：preferredAvatar 指向 ERC-721 usage VC（0x5B5b…/4，chainId 1）
        let didStr = "did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq"
        try await self.store.save(DidEntity(did: didStr, doc: self.fixture("did_swtc"), updatedAt: 1))
        let profile = await self.did.generateProfileVC(didStr)
        XCTAssertEqual(profile?.nickname, "swtc")
        let nft = profile?.nft
        XCTAssertEqual(nft?.contract, "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a")
        XCTAssertEqual(nft?.tokenId, "4")
        XCTAssertEqual(nft?.chainId, 1)
        XCTAssertNil(nft?.image, "未接 SwiftNft → 兜底裸 Nft，无元数据图片")
        XCTAssertEqual(profile?.createdTime, "2026-07-16T02:30:54.936Z", "issuanceDate 透传")
    }

    func testGenerateProfileVCRealEthrPrefersSwtcAvatarVc() async throws {
        // ethr 文档：preferredAvatar 指向 SWTC ownership VC（issuer j9pmAC…/tokenId 43726F…）
        let didStr = "did:ethr:0xa4FdA51E902Ba5f6b6322DEe039be7678Ba4584F"
        try await self.store.save(DidEntity(did: didStr, doc: self.fixture("did_ethr"), updatedAt: 1))
        let profile = await self.did.generateProfileVC(didStr)
        XCTAssertEqual(profile?.nickname, "eth-did")
        XCTAssertEqual(profile?.nft?.contract, "j9pmACHpAV72ngFoSTNshhVtfhgGdQrXpc")
        XCTAssertEqual(profile?.nft?.tokenId, "43726F737320436861696E2044414F2000000000000000000000000000000008")
        XCTAssertNil(profile?.nft?.chainId, "SWTC 兜底裸 Nft 固定 chainId nil（buildSwtcNft）")
        XCTAssertNil(profile?.nft?.image)
    }

    // MARK: - 桥转发（DApp 签名面 / 工具）

    func testDidGenerateBase58PublicKeyForwardsToBridge() async throws {
        self.bridge.stub("generatePublicKeyBase58") { _ in #"{"publicKeyBase58":"abc123","type":"ed25519"}"# }
        let (pk, type) = try await self.did.didGenerateBase58PublicKey(privateKey: "0xsecret")
        XCTAssertEqual(pk, "abc123")
        XCTAssertEqual(type, "ed25519")
        XCTAssertEqual(self.bridge.calls.first?.method, "generatePublicKeyBase58")
        XCTAssertEqual(self.bridge.calls.first?.params?["privateKey"] as? String, "0xsecret")
    }

    func testIpfsPersonalSignForwardsToBridge() async throws {
        self.bridge.stub("ipfsPersonalSign") { params in
            XCTAssertEqual(params?["data"] as? [Int], [1, 2, 3])
            return "signed"
        }
        let signature = try await self.did.ipfsPersonalSign(privateKey: "0xsecret", data: [1, 2, 3])
        XCTAssertEqual(signature, "signed")
    }

    func testIpfsGetPublicKeyForwardsToBridge() async throws {
        self.bridge.stub("ipfsGetPublicKey") { _ in "pubkey" }
        let pub = try await self.did.ipfsGetPublicKey(privateKey: "0xsecret")
        XCTAssertEqual(pub, "pubkey")
    }

    // MARK: - 写操作链（didStat → publishDid → 本地保存）

    func testUpdateDidNicknamePublishesAndSaves() async throws {
        self.bridge.stub("didStat") { _ in #"{"cid":"QmPrevious"}"# }
        self.bridge.stub("publishDid") { _ in #"{"code":"0","message":"ok"}"# }

        let ok = await self.did.updateDidNickname(
            privateKey: "0xsecret",
            did: "did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq",
            nickname: "新昵称",
            currentDoc: self.fixture("did_swtc")
        )
        XCTAssertTrue(ok)
        // 本地已保存更新后的文档
        let entity = try await self.did.getDidDocument("did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq")
        XCTAssertEqual(self.did.nickname(entity?.doc ?? ""), "新昵称")
        // 桥调用序列：didStat 在 publishDid 之前
        let methods = self.bridge.calls.map(\.method)
        XCTAssertEqual(methods.filter { $0 == "didStat" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "publishDid" }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "didStat")), try XCTUnwrap(methods.firstIndex(of: "publishDid")))
    }

    func testUpdateDidNicknameAbortsWhenDidStatFails() async {
        self.bridge.stub("didStat") { _ in throw SwiftDidError.invalidPayload }
        let ok = await self.did.updateDidNickname(
            privateKey: "0xsecret",
            did: "did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq",
            nickname: "x",
            currentDoc: self.fixture("did_swtc")
        )
        XCTAssertFalse(ok, "didStat 失败 → 中止发布（不静默继续）")
        XCTAssertFalse(self.bridge.calls.contains { $0.method == "publishDid" })
    }

    // MARK: - 真实 VC 验证

    func testVerifyCredentialWithRealOwnershipVc() async throws {
        self.bridge.stub("verifyCredential") { _ in #"{"verified":"true","results":[]}"# }
        let result = try await self.did.verifyCredential(self.fixture("swtc_ownership_vc"))
        XCTAssertTrue(result.verified)
        XCTAssertNil(result.errorKind)
    }

    // MARK: - NFT 透传（注入 Fake DidNftResolution）

    func testNftPassthroughForwardsToInjectedNft() async {
        let nft = FakeNftResolver()
        nft.setResult("https://example.com/a.png")
        self.did = SwiftDid(store: self.store, bridge: self.bridge, nft: nft)

        let resolved = await self.did.resolveCredentialImage("ipfs://bafy123/8.png", metadataUri: "ipfs://bafy456/8")
        XCTAssertEqual(resolved, "https://example.com/a.png")
        XCTAssertEqual(nft.calls.count, 1)
        XCTAssertEqual(nft.calls.first?.imageUrl, "ipfs://bafy123/8.png")
        XCTAssertEqual(nft.calls.first?.metadataUri, "ipfs://bafy456/8")
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

/// Fake DidNftResolution：记录 resolveCredentialImage 调用并返回固定结果。
final class FakeNftResolver: DidNftResolution, @unchecked Sendable {
    private let lock = NSLock()
    private var result: String?
    private var _calls: [(imageUrl: String?, metadataUri: String?)] = []

    var calls: [(imageUrl: String?, metadataUri: String?)] {
        self.lock.withLock { self._calls }
    }

    func setResult(_ result: String?) {
        self.lock.withLock { self.result = result }
    }

    func resolveCredentialImage(_ imageUrl: String?, metadataUri: String?) async -> String? {
        self.lock.withLock {
            self._calls.append((imageUrl, metadataUri))
            return self.result
        }
    }

    func resolveSwtcAvatar(vc _: String) async -> Nft? {
        nil
    }

    func resolveEthrAvatar(vc _: String) async -> Nft? {
        nil
    }

    func getAvatarCandidates(account _: WalletAccount) async -> [DidAvatarAsset] {
        []
    }

    func fetchAndCacheNftMeta(contract _: String, tokenId _: String, tokenUri _: String) async -> NftMeta? {
        nil
    }

    func resolveCredentialImage(_: CredentialImageRequest) async -> ResolvedCredentialImage? {
        nil
    }

    func resolveCredentialImages(_ requests: [CredentialImageRequest]) async -> [ResolvedCredentialImage?] {
        Array(repeating: nil, count: requests.count)
    }

    func fetchResolvedMetadataImage(_: String) async -> String? {
        nil
    }

    func normalizeAssetURL(_ rawUrl: String?, baseUrl _: String?) -> String? {
        rawUrl
    }

    func extractResolvedMetadataImageURL(_: String, metadataUri _: String) -> String? {
        nil
    }

    func isSupportedRemoteAssetURL(_ url: String?) -> Bool {
        url != nil
    }

    func extractSwtcMetadataUri(_: String?) -> String? {
        nil
    }

    func fetchMetadataFields(_: String) async -> NftMetadataFields {
        .empty
    }

    func ensureSwtcCredentialMetadata(_: String) async {}
}
