import GRDB
import SwiftDappConnect
@testable import SwiftNft
import XCTest

/// 门面测试：Fake http/swtc/eth 解析器 + 内存 GRDB 存储（对齐 Kotlin NftSdkTest 的用例面）。
final class SwiftNftTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBNftStore!
    private var databaseURL: URL!
    private var http: FakeNftHttpClient!
    private var swtc: FakeSwtcTokenUriResolver!
    private var resolver: FakeEthTokenUriResolver!
    private var sdk: SwiftNft!

    private let gateway = "https://ipfs.jccdex.cn/ipfs/"

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("nft-test-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBNftStore(database: self.database)
        self.http = FakeNftHttpClient()
        self.swtc = FakeSwtcTokenUriResolver()
        self.resolver = FakeEthTokenUriResolver()
        self.sdk = SwiftNft(config: SwiftNftConfig(
            store: self.store,
            httpClient: self.http,
            ethTokenUriResolver: self.resolver,
            swtcTokenUriResolver: self.swtc
        ))
        // 镜像 Kotlin：MockWebServer 类用例禁用 SsrfGuard（Fake 客户端不联网）。
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

    // MARK: getAvatarCandidates

    func testGetAvatarCandidatesMapsSwtcRows() async throws {
        try await self.store.upsertSwtcNfts([
            SwtcNftEntity(ownerAddress: "jcccc", tokenId: "1", fundCode: "FUND", fundCodeName: "",
                          issuer: "issuer", tokenOwner: "jcccc", tokenSender: "jcccc",
                          image: "https://example.com/avatar.png", name: nil, time: 1, block: 1, inservice: 1)
        ])
        let account = WalletAccount(address: "jcccc", chain: .swtc, publicKey: "pub")
        let candidates = await sdk.getAvatarCandidates(account: account)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].name, "FUND", "fundCodeName 空白时回落 fundCode")
        XCTAssertEqual(candidates[0].contract, "issuer")
        XCTAssertTrue(candidates[0].isSwtc)
        XCTAssertNil(candidates[0].chainId)
    }

    func testGetAvatarCandidatesMapsEvmRows() async throws {
        try await self.store.upsertEvmNftItems([
            EvmNftItemEntity(chainId: "0x1", ownerAddress: "0xowner", contractAddress: "0xabc",
                             tokenId: "1", imageUrl: "https://example.com/avatar.png", title: "avatar")
        ])
        let account = WalletAccount(address: "0xowner", chain: .eth, publicKey: "pub")
        let candidates = await sdk.getAvatarCandidates(account: account)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].name, "avatar")
        XCTAssertEqual(candidates[0].chainId, 1)
        XCTAssertFalse(candidates[0].isSwtc)
    }

    func testGetAvatarCandidatesEvmChainWithoutChainIdReturnsEmpty() async {
        // SWTC 无 evmChainId，但 SWTC 走独立分支；此处用 EVM 语义验证 chainId 缺失路径。
        let account = WalletAccount(address: "jcccc", chain: .swtc, publicKey: "pub")
        let candidates = await sdk.getAvatarCandidates(account: account)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: resolveSwtcAvatar 回退链

    private let swtcVC = """
    {"credentialSubject":{"tokenId":"1","nftIssuer":"issuer","tokenName":"avatar"},"issuanceDate":"2025-01-01T00:00:00Z"}
    """

    func testResolveSwtcAvatarPrefersCachedMeta() async throws {
        try await self.store.upsertNftMeta(NftMeta(
            contract: "issuer", tokenId: "1", name: "cached",
            image: "https://example.com/avatar.png", tokenUri: "https://example.com/meta.json",
            fullContent: #"{"name":"cached"}"#, updatedAt: 1
        ))
        let nft = await sdk.resolveSwtcAvatar(vc: self.swtcVC)
        XCTAssertEqual(nft?.name, "cached")
        XCTAssertEqual(nft?.hasLocal, true)
        XCTAssertEqual(nft?.uri, "https://example.com/meta.json")
    }

    func testResolveSwtcAvatarFallsBackToSwtcRow() async throws {
        try await self.store.upsertSwtcNfts([
            SwtcNftEntity(ownerAddress: "jcccc", tokenId: "1", fundCode: "FUND", fundCodeName: "Fund",
                          issuer: "issuer", tokenOwner: "jcccc", tokenSender: "jcccc",
                          metadataUri: "https://example.com/meta.json", image: "https://example.com/avatar.png",
                          name: "avatar", time: 1, block: 1, inservice: 1)
        ])
        let nft = await sdk.resolveSwtcAvatar(vc: self.swtcVC)
        XCTAssertEqual(nft?.name, "avatar")
        XCTAssertEqual(nft?.uri, "https://example.com/meta.json")
        XCTAssertEqual(nft?.image, "https://example.com/avatar.png")
        XCTAssertEqual(nft?.hasLocal, true)
    }

    func testResolveSwtcAvatarFetchesFromChainViaErcInfo() async throws {
        self.swtc.setResult("ipfs://bafy-test/meta.json", for: "1")
        self.http.enqueueJson(#"{"name":"chain","image":"https://example.com/chain.png"}"#,
                              for: "\(self.gateway)bafy-test/meta.json")

        let nft = await sdk.resolveSwtcAvatar(vc: self.swtcVC)

        XCTAssertEqual(nft?.name, "chain")
        XCTAssertEqual(nft?.image, "https://example.com/chain.png")
        XCTAssertEqual(nft?.hasLocal, true)
        XCTAssertEqual(self.swtc.requested, ["1"])
        // 元数据已落 nft_meta（fetchAndCacheNftMeta 预取）
        let meta = try await store.getNftMeta(contract: "issuer", tokenId: "1")
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.tokenUri, "ipfs://bafy-test/meta.json")
    }

    func testResolveSwtcAvatarBareFallback() async {
        let nft = await sdk.resolveSwtcAvatar(vc: self.swtcVC)
        XCTAssertEqual(nft?.name, "avatar")
        XCTAssertEqual(nft?.uri, "")
        XCTAssertNil(nft?.image)
        XCTAssertEqual(nft?.hasLocal, false)
    }

    func testResolveSwtcAvatarMissingSubjectReturnsNil() async {
        let nft = await sdk.resolveSwtcAvatar(vc: #"{"issuanceDate":"x"}"#)
        XCTAssertNil(nft)
    }

    // MARK: resolveEthrAvatar

    func testResolveEthrAvatarUsesResolverUriAndEvmItem() async throws {
        self.resolver.setResult("https://example.com/token.json")
        try await self.store.upsertEvmNftItems([
            EvmNftItemEntity(chainId: "0x1", ownerAddress: "0xowner", contractAddress: "0xabcdef",
                             tokenId: "1", imageUrl: "https://example.com/avatar.png", title: "avatar")
        ])
        let vc = """
        {"credentialSubject":{"tokenId":"1","contractAddress":"0xabcdef","chainId":1},"issuanceDate":"2025-01-01T00:00:00Z"}
        """
        let nft = await sdk.resolveEthrAvatar(vc: vc)
        XCTAssertEqual(nft?.uri, "https://example.com/token.json")
        XCTAssertEqual(nft?.image, "https://example.com/avatar.png")
        XCTAssertEqual(nft?.name, "avatar")
        XCTAssertEqual(nft?.chainId, 1)
    }

    func testResolveEthrAvatarPrefersCachedMeta() async throws {
        self.resolver.setResult("https://example.com/token.json")
        try await self.store.upsertNftMeta(NftMeta(
            contract: "0xabcdef", tokenId: "1", name: "cached",
            image: "https://example.com/cached.png", tokenUri: "https://example.com/cached.json",
            fullContent: #"{}"#, updatedAt: 1
        ))
        let vc = """
        {"credentialSubject":{"tokenId":"1","contractAddress":"0xabcdef","chainId":1},"issuanceDate":"2025-01-01T00:00:00Z"}
        """
        let nft = await sdk.resolveEthrAvatar(vc: vc)
        XCTAssertEqual(nft?.name, "cached")
        XCTAssertEqual(nft?.image, "https://example.com/cached.png")
        XCTAssertEqual(nft?.uri, "https://example.com/cached.json", "本地 tokenUri 优先于 resolver URI")
        XCTAssertEqual(nft?.hasLocal, true)
        XCTAssertEqual(self.resolver.callCount, 0, "本地 tokenUri 命中时惰性跳过 eth_call（对 Kotlin 的优化偏离）")
    }

    func testResolveEthrAvatarCallsResolverWhenLocalTokenUriMissing() async throws {
        // 本地 nft_meta 无 tokenUri（uri 为空）→ 必须调 resolver 兜底。
        self.resolver.setResult("https://example.com/token.json")
        try await self.store.upsertNftMeta(NftMeta(
            contract: "0xabcdef", tokenId: "1", name: "cached",
            image: "https://example.com/cached.png", tokenUri: nil,
            fullContent: #"{}"#, updatedAt: 1
        ))
        let vc = """
        {"credentialSubject":{"tokenId":"1","contractAddress":"0xabcdef","chainId":1},"issuanceDate":"2025-01-01T00:00:00Z"}
        """
        let nft = await sdk.resolveEthrAvatar(vc: vc)
        XCTAssertEqual(nft?.uri, "https://example.com/token.json")
        XCTAssertEqual(self.resolver.callCount, 1, "本地缺 tokenUri 时必须调 resolver")
    }

    // MARK: fetchAndCacheNftMeta

    func testFetchAndCacheNftMetaPersists() async throws {
        self.http.enqueueJson(#"{"name":"avatar","image":"https://example.com/avatar.png"}"#,
                              for: "https://example.com/meta.json")
        let meta = await sdk.fetchAndCacheNftMeta(contract: "issuer", tokenId: "1", tokenUri: "https://example.com/meta.json")
        XCTAssertEqual(meta?.name, "avatar")
        XCTAssertEqual(meta?.image, "https://example.com/avatar.png")
        let persisted = try await store.getNftMeta(contract: "issuer", tokenId: "1")
        XCTAssertEqual(persisted?.image, "https://example.com/avatar.png")
    }

    func testFetchAndCacheNftMetaBlankTokenUriReturnsNil() async {
        let meta = await sdk.fetchAndCacheNftMeta(contract: "issuer", tokenId: "1", tokenUri: "  ")
        XCTAssertNil(meta)
        XCTAssertEqual(self.http.jsonRequestCount, 0)
    }

    func testFetchAndCacheNftMetaNormalizesIpfsUri() async {
        self.http.enqueueJson(#"{"name":"avatar","image":"https://example.com/avatar.png"}"#,
                              for: "\(self.gateway)bafy123/meta.json")
        let meta = await sdk.fetchAndCacheNftMeta(contract: "issuer", tokenId: "1", tokenUri: "ipfs://bafy123/meta.json")
        XCTAssertEqual(meta?.image, "https://example.com/avatar.png")
        XCTAssertEqual(self.http.jsonRequestURLs, ["\(self.gateway)bafy123/meta.json"], "ipfs:// 先归一化再拉取")
    }

    // MARK: resolveCredentialImage

    func testResolveCredentialImagePrefersMetadataImageWhenImageUrlBlank() async {
        self.http.enqueueText(#"{"image":"ipfs://bafy-test/avatar.png"}"#, for: "\(self.gateway)bafy-test/meta.json")
        let resolved = await sdk.resolveCredentialImage(nil, metadataUri: "ipfs://bafy-test/meta.json")
        XCTAssertEqual(resolved, "\(self.gateway)bafy-test/avatar.png")
    }

    func testResolveCredentialImageReturnsMetadataUriWhenItIsImageUrl() async {
        let resolved = await sdk.resolveCredentialImage(nil, metadataUri: "https://example.com/avatar.png")
        XCTAssertEqual(resolved, "https://example.com/avatar.png")
        XCTAssertEqual(self.http.textRequestCount, 0, "metadataUri 本身是图片 URL 时不拉网络")
    }

    func testResolveCredentialImageUsesImageUrlDirectly() async {
        let resolved = await sdk.resolveCredentialImage("https://example.com/a.png", metadataUri: "https://example.com/meta.json")
        XCTAssertEqual(resolved, "https://example.com/a.png")
        XCTAssertEqual(self.http.textRequestCount, 0)
    }

    func testResolveCredentialImageRejectsNonImageDataImageUrl() async {
        // 设计决策：直出前仅放行 data:image/*（02 §8）；非图片 data: 不得直出、也不得触发网络。
        let resolved = await sdk.resolveCredentialImage("data:text/html,<script>", metadataUri: nil)
        XCTAssertNil(resolved, "非 data:image/* 的 imageUrl 不得直出")
        XCTAssertEqual(self.http.textRequestCount, 0)
    }

    func testResolveCredentialImageRejectsNonImageDataMetadataUri() async {
        let resolved = await sdk.resolveCredentialImage(nil, metadataUri: "data:text/html,<script>")
        XCTAssertNil(resolved, "非 data:image/* 的 metadataUri 不得直出")
        XCTAssertEqual(self.http.textRequestCount, 0)
    }

    func testResolveCredentialImageAllowsDataImageUrl() async {
        let dataImage = "data:image/png;base64,iVBORw0KGgo="
        let resolved = await sdk.resolveCredentialImage(dataImage, metadataUri: nil)
        XCTAssertEqual(resolved, dataImage, "data:image/* 直出放行")
        XCTAssertEqual(self.http.textRequestCount, 0)
    }

    func testResolveCredentialImageExtractsInlineJsonImageUrl() async {
        let inline = #"{"image":"https://example.com/inline.png"}"#
        let resolved = await sdk.resolveCredentialImage(inline, metadataUri: "https://example.com/meta.json")
        XCTAssertEqual(resolved, "https://example.com/inline.png")
    }

    func testResolveCredentialImageRetriesAfterTransientFailure() async {
        self.http.enqueueText(nil, for: "https://example.com/meta.json")
        self.http.enqueueText(#"{"image":"https://example.com/avatar.png"}"#, for: "https://example.com/meta.json")

        let first = await sdk.resolveCredentialImage(nil, metadataUri: "https://example.com/meta.json")
        let second = await sdk.resolveCredentialImage(nil, metadataUri: "https://example.com/meta.json")

        XCTAssertNil(first)
        XCTAssertEqual(second, "https://example.com/avatar.png")
        XCTAssertEqual(self.http.textRequestCount, 2, "瞬时失败不缓存、可重试（对齐 Kotlin 测试锁定行为）")
    }

    func testResolveCredentialImageStructuredRequestBuildsCacheKey() async {
        self.http.enqueueText(#"{"image":"https://example.com/avatar.png"}"#, for: "https://example.com/meta.json")
        let request = CredentialImageRequest(imageUrl: nil, metadataUri: "https://example.com/meta.json",
                                             chainId: 1_440_000, contractAddress: "issuer", tokenId: "1")
        let resolved = await sdk.resolveCredentialImage(request)
        XCTAssertEqual(resolved?.url, "https://example.com/avatar.png")
        XCTAssertTrue(resolved?.cacheKey.hasPrefix("image:") == true, "解析出 URL 时 cacheKey = image:<url>")
    }

    func testResolveCredentialImagesDeduplicatesIdenticalRequests() async {
        self.http.enqueueText(#"{"image":"https://example.com/avatar.png"}"#, for: "https://example.com/meta.json")
        let request = CredentialImageRequest(imageUrl: nil, metadataUri: "https://example.com/meta.json",
                                             chainId: 1_440_000, contractAddress: "issuer", tokenId: "1")
        let resolved = await sdk.resolveCredentialImages([request, request])

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0], resolved[1])
        XCTAssertEqual(self.http.textRequestCount, 1, "相同请求只拉一次（对齐 Kotlin getOrPut 去重）")
    }

    func testResolveCredentialImagesParallelMixedKeysPreservesOrderAndDedup() async {
        self.http.enqueueText(#"{"image":"https://example.com/a.png"}"#, for: "https://example.com/meta-a.json")
        self.http.enqueueText(#"{"image":"https://example.com/b.png"}"#, for: "https://example.com/meta-b.json")
        let a = CredentialImageRequest(imageUrl: nil, metadataUri: "https://example.com/meta-a.json",
                                       chainId: 1, contractAddress: "issuer", tokenId: "1")
        let b = CredentialImageRequest(imageUrl: nil, metadataUri: "https://example.com/meta-b.json",
                                       chainId: 1, contractAddress: "issuer", tokenId: "2")

        let resolved = await sdk.resolveCredentialImages([a, b, a, b])

        XCTAssertEqual(resolved.count, 4)
        XCTAssertEqual(resolved[0]?.url, "https://example.com/a.png")
        XCTAssertEqual(resolved[1]?.url, "https://example.com/b.png")
        XCTAssertEqual(resolved[2], resolved[0], "重复 key 复用同一解析结果")
        XCTAssertEqual(resolved[3], resolved[1])
        XCTAssertEqual(self.http.textRequestCount, 2, "两个唯一 key 各拉一次（有界并发 + 去重）")
    }

    func testResolveCredentialImagesEmptyReturnsEmpty() async {
        let resolved = await sdk.resolveCredentialImages([])
        XCTAssertTrue(resolved.isEmpty)
    }

    // MARK: fetchResolvedMetadataImage / fetchMetadataFields

    func testFetchResolvedMetadataImage() async {
        self.http.enqueueText(#"{"image":"https://example.com/a.png"}"#, for: "https://example.com/meta.json")
        let resolved = await sdk.fetchResolvedMetadataImage("https://example.com/meta.json")
        XCTAssertEqual(resolved, "https://example.com/a.png")
    }

    func testFetchMetadataFieldsUnwrapsData() async {
        self.http.enqueueText(#"{"data":{"name":"avatar","description":"hello","image":"./images/avatar.png"}}"#,
                              for: "https://example.com/meta.json")
        let fields = await sdk.fetchMetadataFields("https://example.com/meta.json")
        XCTAssertEqual(fields.name, "avatar")
        XCTAssertEqual(fields.description, "hello")
        XCTAssertEqual(fields.image, "https://example.com/images/avatar.png")
    }

    func testFetchMetadataFieldsFailureReturnsEmptyWithoutThrowing() async {
        self.http.enqueueText(nil, for: "https://example.com/meta.json")
        let fields = await sdk.fetchMetadataFields("https://example.com/meta.json")
        XCTAssertNil(fields.image)
        XCTAssertNil(fields.name)
        XCTAssertNil(fields.description)
    }

    // MARK: 纯函数包装（经 config.ipfsGateway）

    func testNormalizeAssetUrlUsesInjectedGateway() {
        XCTAssertEqual(self.sdk.normalizeAssetUrl("ipfs://bafy123/a.png", baseUrl: nil), "\(self.gateway)bafy123/a.png")
    }

    func testIsSupportedRemoteAssetUrlWrapper() {
        XCTAssertTrue(self.sdk.isSupportedRemoteAssetUrl("https://example.com/a.png"))
        XCTAssertFalse(self.sdk.isSupportedRemoteAssetUrl("ipfs://bafy123/a.png"))
    }

    func testExtractResolvedMetadataImageUrlWrapper() {
        XCTAssertEqual(
            self.sdk.extractResolvedMetadataImageUrl(#"{"image":"./nft/a.png"}"#, metadataUri: "https://example.com/meta.json"),
            "https://example.com/nft/a.png"
        )
    }

    func testExtractSwtcMetadataUriWrapper() {
        let payload = """
        [ { "TokenInfo": { "InfoType": "746f6b656e557269", "InfoData": "697066733a2f2f626166792d746573742f6d6574612e6a736f6e" } } ]
        """
        XCTAssertEqual(self.sdk.extractSwtcMetadataUri(payload), "\(self.gateway)bafy-test/meta.json")
    }

    func testExtractSwtcMetadataUriUsesInjectedGateway() {
        // 网关贯穿：SWTC 元数据 URI 的 ipfs→网关重写必须用注入网关（04 坑 #9⑥）；无尾斜杠也应规范化。
        let custom = SwiftNft(config: SwiftNftConfig(
            store: self.store,
            ipfsGateway: "https://gateway.example.com/ipfs",
            httpClient: self.http,
            ethTokenUriResolver: self.resolver,
            swtcTokenUriResolver: self.swtc
        ))
        let payload = """
        [ { "TokenInfo": { "InfoType": "746f6b656e557269", "InfoData": "697066733a2f2f626166792d746573742f6d6574612e6a736f6e" } } ]
        """
        XCTAssertEqual(custom.extractSwtcMetadataUri(payload), "https://gateway.example.com/ipfs/bafy-test/meta.json")
    }

    // MARK: ensureSwtcCredentialMetadata

    func testEnsureSwtcCredentialMetadataPrefetches() async {
        self.swtc.setResult("https://example.com/meta.json", for: "1")
        self.http.enqueueJson(#"{"name":"avatar","image":"https://example.com/avatar.png"}"#,
                              for: "https://example.com/meta.json")
        await self.sdk.ensureSwtcCredentialMetadata(self.swtcVC)
        let meta = try? await store.getNftMeta(contract: "issuer", tokenId: "1")
        XCTAssertEqual(meta?.image, "https://example.com/avatar.png")
    }
}

// MARK: - Fakes

/// Fake HTTP 客户端：按 URL 排队响应 + 请求计数（线程安全）。
final class FakeNftHttpClient: NftHttpClient, @unchecked Sendable {
    private let lock = NSLock()
    private var jsonQueues: [String: [Data?]] = [:]
    private var textQueues: [String: [String?]] = [:]
    private var _jsonRequestCount = 0
    private var _textRequestCount = 0
    private var _jsonRequestURLs: [String] = []
    private var _textRequestURLs: [String] = []

    var jsonRequestCount: Int {
        self.lock.withLock { self._jsonRequestCount }
    }

    var textRequestCount: Int {
        self.lock.withLock { self._textRequestCount }
    }

    var jsonRequestURLs: [String] {
        self.lock.withLock { self._jsonRequestURLs }
    }

    var textRequestURLs: [String] {
        self.lock.withLock { self._textRequestURLs }
    }

    func enqueueJson(_ body: String?, for url: String) {
        self.lock.withLock { self.jsonQueues[url, default: []].append(body?.data(using: .utf8)) }
    }

    func enqueueText(_ body: String?, for url: String) {
        self.lock.withLock { self.textQueues[url, default: []].append(body) }
    }

    func fetchJson(_ url: URL) async throws -> Data? {
        self.lock.withLock {
            self._jsonRequestCount += 1
            self._jsonRequestURLs.append(url.absoluteString)
            guard var queue = jsonQueues[url.absoluteString], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            self.jsonQueues[url.absoluteString] = queue // 值类型数组必须写回，否则每次弹同一个首元素
            return first
        }
    }

    func fetchText(_ url: URL) async throws -> String? {
        self.lock.withLock {
            self._textRequestCount += 1
            self._textRequestURLs.append(url.absoluteString)
            guard var queue = textQueues[url.absoluteString], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            self.textQueues[url.absoluteString] = queue // 值类型数组必须写回，否则每次弹同一个首元素
            return first
        }
    }
}

/// Fake SWTC erc_info 拉取器。
final class FakeSwtcTokenUriResolver: ISwtcTokenUriResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: String?] = [:]
    private var _requested: [String] = []

    var requested: [String] {
        self.lock.withLock { self._requested }
    }

    func setResult(_ uri: String?, for tokenId: String) {
        self.lock.withLock { self.results[tokenId] = uri }
    }

    func fetchMetadataUri(tokenId: String) async -> String? {
        self.lock.withLock {
            self._requested.append(tokenId)
            return self.results[tokenId] ?? nil
        }
    }
}

/// Fake EVM tokenURI 解析器。
final class FakeEthTokenUriResolver: IEthTokenUriResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var result: String?
    private var _callCount = 0
    private var _lastContract = ""
    private var _lastTokenId = ""
    private var _lastChainId: Int64 = 0

    var callCount: Int {
        self.lock.withLock { self._callCount }
    }

    var lastContract: String {
        self.lock.withLock { self._lastContract }
    }

    var lastTokenId: String {
        self.lock.withLock { self._lastTokenId }
    }

    var lastChainId: Int64 {
        self.lock.withLock { self._lastChainId }
    }

    func setResult(_ result: String?) {
        self.lock.withLock { self.result = result }
    }

    func resolveEthrTokenUri(contract: String, tokenId: String, chainId: Int64) async -> String? {
        self.lock.withLock {
            self._callCount += 1
            self._lastContract = contract
            self._lastTokenId = tokenId
            self._lastChainId = chainId
            return self.result
        }
    }
}
