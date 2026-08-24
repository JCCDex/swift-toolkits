import GRDB
import SwiftCore
import SwiftDappConnect
@testable import SwiftDid
import SwiftNft
import SwiftWebviewBridge
import XCTest

/// 门面测试：Fake 桥 + GRDB 临时文件库（对齐 Kotlin DidSdkTest 的关键用例面）。
@MainActor
final class SwiftDidTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBDidStore!
    private var bridge: FakeDidBridge!
    private var databaseURL: URL!
    private var did: SwiftDid!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("did-facade-\(UUID().uuidString).sqlite")
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

    // MARK: - 基础面

    func testToDidEthChecksumsAddress() {
        let account = WalletAccount(address: "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", chain: .eth)
        XCTAssertEqual(self.did.toDid(account), "did:ethr:0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    }

    func testToDidSwtcKeepsAddress() {
        let account = WalletAccount(address: "jB7rxgh1n1B2Wt7YbYq3F1c2LkzQvPqR8sT", chain: .swtc)
        XCTAssertEqual(self.did.toDid(account), "did:swtc:jB7rxgh1n1B2Wt7YbYq3F1c2LkzQvPqR8sT")
    }

    // MARK: - formatUtc（Asia/Shanghai 时区换算，直接锁定时区与解析路径）

    func testFormatUtcConvertsToShanghai() {
        // 无小数位输入（ISO8601DateFormatter 双形态解析路径）
        XCTAssertEqual(Date.formatUtc("2025-01-01T00:00:00Z"), "2025-01-01 08:00:00")
        XCTAssertEqual(Date.formatUtc("2025-01-01T16:30:00Z"), "2025-01-02 00:30:00", "跨日边界")
    }

    func testFormatUtcHandlesFractionalSeconds() {
        XCTAssertEqual(Date.formatUtc("2025-01-01T00:00:00.5Z"), "2025-01-01 08:00:00", "小数秒不进位到展示层")
        XCTAssertEqual(Date.formatUtc("2025-01-01T08:00:00.123Z"), "2025-01-01 16:00:00")
    }

    func testFormatUtcBlankOrInvalidReturnsAsIs() {
        XCTAssertEqual(Date.formatUtc(""), "")
        XCTAssertEqual(Date.formatUtc("not-a-date"), "not-a-date")
    }

    func testFormatAddress() {
        XCTAssertEqual(self.did.formatAddress("0x1234567890abcdef"), "0x12***cdef")
        XCTAssertEqual(self.did.formatAddress("short"), "short")
    }

    func testGetProfileAndNickname() {
        let doc = #"{"service":[{"type":"Profile","serviceEndpoint":{"nickname":"alice","preferredAvatar":"vc-1"}}]}"#
        XCTAssertEqual(self.did.nickname(doc), "alice")
        XCTAssertEqual(self.did.getProfile(doc)?.preferredAvatar, "vc-1")
        XCTAssertNil(self.did.getProfile(#"{"service":[]}"#))
    }

    // MARK: - DApp 签名面（M-15 结构校验）

    func testSignCredentialForDAppRejectsMissingCredential() async {
        do {
            _ = try await self.did.signCredential(privateKey: "0x1", vcJson: #"{"keyDoc":{"did":"d","id":"i"}}"#)
            XCTFail("缺 credential 应抛 invalidCredential")
        } catch SwiftDidError.invalidCredential {
            // 预期
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    func testSignCredentialForDAppRejectsMissingKeyDoc() async {
        let payload = #"{"credential":{"@context":"c","credentialSubject":{},"issuer":"i"}}"#
        do {
            _ = try await self.did.signCredential(privateKey: "0x1", vcJson: payload)
            XCTFail("缺 keyDoc.did/id 应抛 invalidCredential")
        } catch SwiftDidError.invalidCredential {
            // 预期
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    func testSignCredentialForDAppInjectsPrivateKeyAndForwards() async throws {
        var receivedParams: [String: Any]?
        self.bridge.stub("signCredential") { params in
            receivedParams = params
            return #"{"signed":true}"#
        }
        let payload = #"{"credential":{"@context":"c","credentialSubject":{},"issuer":"i"},"keyDoc":{"did":"did:swtc:aaa","id":"did:swtc:aaa#key-1"}}"#
        let result = try await did.signCredential(privateKey: "0xsecret", vcJson: payload)
        XCTAssertEqual(result, #"{"signed":true}"#)
        XCTAssertEqual(receivedParams?["privateKey"] as? String, "0xsecret", "桥调用必须带上 privateKey")
    }

    // MARK: - VC 校验

    func testVerifyCredentialExpiredReturnsFalseWithoutBridgeCall() async throws {
        let expired = #"{"expirationDate":"2020-01-01T00:00:00Z"}"#
        let result = try await did.verifyCredential(expired)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(self.bridge.calls.count, 0, "过期直接 false，不调桥")
    }

    func testVerifyCredentialMalformedExpirationFailsClosed() async throws {
        // P0-6：非空但无法解析的 expirationDate（攻击者可控）不得跳过过期检查——fail-closed
        let malformed = #"{"expirationDate":"not-a-date"}"#
        let result = try await did.verifyCredential(malformed)
        XCTAssertFalse(result.verified, "畸形过期时间 → 不得通过")
        XCTAssertEqual(result.errorKind, "invalidExpirationDate", "带明确 errorKind 便于排查")
        XCTAssertEqual(self.bridge.calls.count, 0, "畸形过期时间直接失败，不调桥")
    }

    func testVerifyCredentialFutureExpirationProceedsToBridge() async throws {
        // 有效未来日期仍应走到桥接验证（防过度拦截）
        self.bridge.stub("verifyCredential") { _ in #"{"verified":true,"results":[],"errorKind":"","error":""}"# }
        let future = #"{"expirationDate":"2999-01-01T00:00:00Z"}"#
        let result = try await did.verifyCredential(future)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(self.bridge.calls.count, 1, "未来日期 → 调桥验证")
    }

    func testVerifyCredentialHappyPathPreservesErrorKind() async throws {
        self.bridge.stub("verifyCredential") { _ in #"{"verified":true,"results":[],"errorKind":"","error":""}"# }
        let result = try await did.verifyCredential(#"{"type":["VerifiableCredential"]}"#)
        XCTAssertTrue(result.verified)
    }

    func testVerifyCredentialFailedPreservesErrorKind() async throws {
        self.bridge.stub("verifyCredential") { _ in #"{"verified":false,"errorKind":"SignatureError","error":"bad signature"}"# }
        let result = try await did.verifyCredential(#"{"type":["VerifiableCredential"]}"#)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.errorKind, "SignatureError", "Swift 增强：保留 errorKind（Kotlin 丢弃）")
        XCTAssertEqual(result.error, "bad signature")
    }

    func testVerifyCredentialBlankThrows() async {
        do {
            _ = try await self.did.verifyCredential("")
            XCTFail("空白 credential 应抛 invalidPayload")
        } catch SwiftDidError.invalidPayload {
            // 预期
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    // MARK: - 写操作

    func testUploadInitialDidDocHappyPath() async throws {
        self.bridge.stub("generatePublicKeyBase58") { _ in #"{"type":"EcdsaSecp256k1VerificationKey2019","publicKeyBase58":"pubkey"}"# }
        self.bridge.stub("didStat") { _ in #"{"cid":"cid-1"}"# }
        self.bridge.stub("generateDidDoc") { _ in #"{"version":"1.0.0","credentials":[1]}"# }
        self.bridge.stub("publishDid") { _ in #"{"code":"0","message":"ok"}"# }

        let ok = await did.uploadInitialDidDoc(privateKey: "0x1", did: "did:swtc:aaa", nickname: "alice")
        XCTAssertTrue(ok)
        let entity = try await store.get("did:swtc:aaa")
        XCTAssertNotNil(entity)
        XCTAssertNotNil(try Json.parseObject(XCTUnwrap(entity?.doc))?["credentials"], "初始文档必须带 credentials 数组")
        XCTAssertEqual(self.bridge.calls.filter { $0.method == "publishDid" }.count, 1)
    }

    func testUploadInitialDidDocDidStatFailureFails() async {
        // didStat 失败 = 发布失败（Swift 修正：不重试，不静默吞错）
        self.bridge.stub("generatePublicKeyBase58") { _ in #"{"type":"t","publicKeyBase58":"pub"}"# }
        self.bridge.stub("didStat") { _ in "garbage-not-cid" } // 解码失败 → nil
        self.bridge.stub("publishDid") { _ in #"{"code":"0","message":"ok"}"# }

        let ok = await did.uploadInitialDidDoc(privateKey: "0x1", did: "did:swtc:aaa")
        XCTAssertFalse(ok)
        XCTAssertEqual(self.bridge.calls.filter { $0.method == "publishDid" }.count, 0, "didStat 失败不得继续发布")
    }

    func testPublishDidDeleteClearsLocal() async throws {
        try await self.store.save(DidEntity(did: "did:swtc:bbb", doc: #"{"updated":"2025-01-01T00:00:00.000Z"}"#, updatedAt: 1))
        self.bridge.stub("publishDid") { _ in #"{"code":"0","message":"ok"}"# }
        let ok = await did.publishDidDelete(privateKey: "0x1", did: "did:swtc:bbb")
        XCTAssertTrue(ok)
        let remaining = try? await store.get("did:swtc:bbb")
        XCTAssertNil(remaining)
        let pending = try await store.loadPending(kind: DidCoreService.pendingDelete, did: "did:swtc:bbb")
        XCTAssertNotNil(pending, "删除时间戳入 pending")
    }

    // MARK: - 展示模型

    func testGenerateProfileVCBuildsSwtcNftFromCredential() async throws {
        let credential = #"{"id":"did:swtc:ccc#nft-avatar-issuer-1-did:swtc:ccc","type":["VerifiableCredential","NFTOwnership"],"credentialSubject":{"tokenId":"1","nftIssuer":"issuer","tokenName":"avatar"},"issuanceDate":"2025-01-01T00:00:00Z"}"#
        let doc = #"{"updated":"2025-01-01T00:00:00.000Z","service":[{"type":"Profile","serviceEndpoint":{"nickname":"alice","preferredAvatar":"did:swtc:ccc#nft-avatar-issuer-1-did:swtc:ccc"}}],"credentials":[\#(credential)]}"#
        try await store.save(DidEntity(did: "did:swtc:ccc", doc: doc, updatedAt: 1))

        let profileVC = await did.generateProfileVC("did:swtc:ccc")
        XCTAssertEqual(profileVC?.nickname, "alice")
        XCTAssertEqual(profileVC?.nft?.name, "avatar")
        XCTAssertEqual(profileVC?.nft?.tokenId, "1")
        XCTAssertEqual(profileVC?.createdTime, "2025-01-01T00:00:00Z")
    }

    func testGetAvatarNftCredentialsUsesCredentialSource() async {
        let source = FakeAvatarCredentialSource()
        source.assets = [
            DidAvatarAsset(image: "https://example.com/a.png", name: "avatar", contract: nil,
                           tokenId: "1", issuer: "issuer", tokenName: "avatar", chainId: nil, isSwtc: true)
        ]
        self.did = SwiftDid(store: self.store, bridge: self.bridge, avatarCredentialSource: source)

        let account = WalletAccount(address: "jB7rxgh1n1B2Wt7YbYq3F1c2LkzQvPqR8sT", chain: .swtc)
        let credentials = await did.getAvatarNftCredentials(account: account)
        XCTAssertNotNil(credentials)
        XCTAssertEqual(credentials[0].ownerDid, "did:swtc:jB7rxgh1n1B2Wt7YbYq3F1c2LkzQvPqR8sT")
        XCTAssertTrue(credentials[0].credentialId.hasPrefix("did:swtc:jB7rxgh1n1B2Wt7YbYq3F1c2LkzQvPqR8sT#nft-avatar-issuer-1-"))
    }

    // MARK: - NFT 透传（nft 未接入 → nil/空）

    func testNftPassthroughReturnsNilWhenNoNft() async {
        let image = await did.resolveCredentialImage(nil, metadataUri: "https://example.com/m.json")
        let fields = await did.fetchMetadataFields("https://example.com/m.json")
        let resolved = await did.fetchResolvedMetadataImage("https://example.com/m.json")
        let uri = await did.extractSwtcMetadataUri("[]")
        let images = await did.resolveCredentialImages([])
        XCTAssertNil(image)
        XCTAssertNil(fields)
        XCTAssertNil(resolved)
        XCTAssertNil(uri)
        XCTAssertFalse(self.did.isSupportedRemoteAssetURL("https://example.com/a.png"))
        XCTAssertEqual(images, [])
    }

    // MARK: - resolveDid 三态

    func testResolveDidMissingOutcome() async {
        self.bridge.stub("didResolve") { _ in "null" }
        let outcome = await did.resolveDid("did:swtc:ddd")
        guard case .missing = outcome else { return XCTFail("应为 missing，实际 \(outcome)") }
    }

    func testResolveDidDocumentOutcome() async {
        self.bridge.stub("didResolve") { _ in #"{"updated":"2025-01-01T00:00:00.000Z"}"# }
        let outcome = await did.resolveDid("did:swtc:eee")
        guard case let .document(doc) = outcome else { return XCTFail() }
        XCTAssertTrue(doc.contains("updated"))
        let saved = try? await store.get("did:swtc:eee")
        XCTAssertEqual(saved?.doc, doc)
    }

    // MARK: - 生命周期

    func testStartInvokesBridgeStartExactlyOnce() throws {
        // 四、架构观察 #3 回归：start 不得对具体类型 WebViewBridgeEngine 特判——
        // 注入的自定义 EngineBridge 也必须被启动；SwiftDid 自身幂等。
        XCTAssertEqual(self.bridge.startCount, 0)
        try self.did.start()
        XCTAssertEqual(self.bridge.startCount, 1, "自定义 EngineBridge 也必须被 start（不再特判具体类型）")
        try self.did.start()
        XCTAssertEqual(self.bridge.startCount, 1, "SwiftDid.start 幂等：不重复启动桥")
    }
}

// MARK: - Fakes

/// Fake 桥（@MainActor，遵循 EngineBridge 协议）：方法级脚本化响应 + 调用记录。
@MainActor
final class FakeDidBridge: EngineBridge {
    private var handlers: [String: ([String: Any]?) throws -> String] = [:]
    private(set) var calls: [(method: String, params: [String: Any]?)] = []
    /// start() 调用次数（P0/四#3 回归：任何 EngineBridge 都必须被 SwiftDid.start 启动）。
    private(set) var startCount = 0

    func stub(_ method: String, _ handler: @escaping ([String: Any]?) throws -> String) {
        self.handlers[method] = handler
    }

    func start() throws {
        self.startCount += 1
    }

    func call(method: String, params: [String: Any]?) async throws -> String {
        self.calls.append((method, params))
        guard let handler = handlers[method] else { return "null" }
        return try handler(params)
    }

    func call(method: String, params: [String: Any]?, timeoutMs _: TimeInterval, readyWaitMs _: TimeInterval) async throws -> String {
        try await self.call(method: method, params: params)
    }

    func callTyped<T: Decodable>(method: String, params: [String: Any]?, asType _: T.Type) async throws -> T {
        let raw = try await call(method: method, params: params)
        if T.self == String.self, let string = raw as? T {
            return string
        }
        guard let data = raw.data(using: .utf8) else {
            throw SwiftDidError.invalidPayload
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func callTyped<T: Decodable>(method: String, params: [String: Any]?, asType type: T.Type, timeoutMs _: TimeInterval, readyWaitMs _: TimeInterval) async throws -> T {
        try await self.callTyped(method: method, params: params, asType: type)
    }

    func destroy() {}
}

/// Fake 头像候选源。
@MainActor
final class FakeAvatarCredentialSource: DidAvatarCredentialSource {
    var assets: [DidAvatarAsset] = []

    func getAvatarCandidates(account _: WalletAccount) async -> [DidAvatarAsset] {
        self.assets
    }
}
