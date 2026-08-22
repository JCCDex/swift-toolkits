import Foundation
import SwiftCore
import SwiftDappConnect
import SwiftNft
import SwiftWebviewBridge

// MARK: - 阶段二 DTO 归属（见 Nft-Swift 02 §2）

//
// `Nft` / `NftMetadataFields` / `CredentialImageRequest` / `ResolvedCredentialImage` / `DidAvatarAsset` /
// `IEthTokenUriResolver` / `NftMeta` / `DidNftResolution` 已迁入 SwiftNft，本模块经 `import SwiftNft`
// **直接使用非限定名**（`SwiftNft.Nft` 限定拼写不可用——模块名与门面类同名 `SwiftNft.SwiftNft`，
// 类型位置会解析到类；消费者 `import SwiftNft` 后用 `Nft` 即可，行为与 typealias 等价）。

// MARK: - 宿主注入点（对齐 Kotlin port 层 IDidAvatarResolver / IDidAvatarCredentialSource）

/// 宿主头像解析（回退链第 1 级，优先于 SwiftNft）。
public protocol DidAvatarResolver: AnyObject, Sendable {
    func resolveSwtcAvatar(vc: String) async -> Nft?
    func resolveEthrAvatar(vc: String) async -> Nft?
}

/// 宿主头像候选源（`getAvatarNftCredentials` 优先走它，避免耦合 App DB schema）。
public protocol DidAvatarCredentialSource: AnyObject, Sendable {
    func getAvatarCandidates(account: WalletAccount) async -> [DidAvatarAsset]
}

// MARK: - SwiftDid 门面

/// 门面（对齐 Kotlin `DidSdk`）：生命周期 + 全部类型化 API。
///
/// 线程模型（见 Did-Swift 02 §7）：门面与 `DidCoreService` 编排层保持 **@MainActor**（桥调用免 hop、
/// pending 对账互斥简单）；`DidStore` / `DidResolver` / `DidNftResolution` 等 I/O 协议自由线程。
@MainActor
public final class SwiftDid: DidSDK {
    private let bridge: any EngineBridge
    private let store: any DidStore
    private let core: DidCoreService
    private let resolver: any DidResolver
    private let nft: (any DidNftResolution)? // 预留：SwiftNft 模块接入点（阶段二，见 Nft-Swift 02 §2）
    private let avatarResolver: (any DidAvatarResolver)?
    private let avatarCredentialSource: (any DidAvatarCredentialSource)?
    private var started = false

    public init(
        store: any DidStore,
        bridge: any EngineBridge = WebviewBridgeEngine(bridgeFileName: "did-bridge.html"),
        nft: (any DidNftResolution)? = nil,
        avatarResolver: (any DidAvatarResolver)? = nil,
        avatarCredentialSource: (any DidAvatarCredentialSource)? = nil
    ) {
        self.store = store
        self.bridge = bridge
        self.nft = nft
        self.avatarResolver = avatarResolver
        self.avatarCredentialSource = avatarCredentialSource
        let resolver = BridgeDidResolver(bridge: bridge)
        self.resolver = resolver
        self.core = DidCoreService(store: store, resolver: resolver)
    }

    // MARK: - 生命周期

    public func start() throws {
        guard !self.started else { return }
        if let engine = bridge as? WebviewBridgeEngine {
            try engine.start() // 网关保持 did-bridge.js 硬编码（见 Did-Swift 03 §3），无需注入
        }
        // 启动时做一次 did_pending 全表 TTL 清理（不启动定时器，见 Did-Swift 01 §6）
        Task {
            try? await self.core.deleteExpiredPending(now: DidCoreService.nowMillis(), ttlMillis: DidCoreService.pendingTTLMillis)
        }
        self.started = true
    }

    public func destroy() {
        self.bridge.destroy()
        self.started = false
    }

    // MARK: - DID / Profile（同步面）

    public func toDid(_ wallet: WalletAccount?) -> String {
        guard let wallet else { return "" }
        switch wallet.chain {
        case .swtc:
            return "did:swtc:\(wallet.address)"
        default:
            let checksum = ChecksumUtils.toChecksumAddress(wallet.address, or: wallet.address)
            return "did:ethr:\(checksum)"
        }
    }

    public func formatAddress(_ address: String) -> String {
        if address.count <= 8 {
            return address
        }
        return String(address.prefix(4)) + "***" + String(address.suffix(4))
    }

    public func nickname(_ doc: String) -> String {
        self.getProfile(doc)?.nickname ?? ""
    }

    public func getProfile(_ doc: String) -> Profile? {
        guard let root = DidJson.parseObject(doc) else { return nil }
        return self.getProfile(root)
    }

    private func getProfile(_ root: [String: Any]) -> Profile? {
        let nickname = DidJson.readProfileField(root, "nickname")
        let preferredAvatar = DidJson.readProfileField(root, "preferredAvatar")
        if nickname != nil || preferredAvatar != nil {
            return Profile(nickname: nickname ?? "", preferredAvatar: preferredAvatar ?? "")
        }
        return nil
    }

    public func readCredentials(_ doc: String) -> [String] {
        DidCredentialHelper.readCredentials(doc).compactMap { credential -> String? in
            guard let object = credential as? [String: Any] else { return nil }
            return DidJson.stringify(object)
        }
    }

    // MARK: - 观察 / 取档

    public func observeDidDocument(_ did: String) -> AsyncStream<DidEntity?> {
        self.core.observe(did)
    }

    public func observeAllDidDocuments() -> AsyncStream<[DidEntity]> {
        self.core.observeAll()
    }

    public func getDidDocument(_ did: String) async throws -> DidEntity? {
        try await self.core.getDidDocument(did)
    }

    public func resolveDid(_ did: String) async -> DidResolveOutcome {
        await self.core.resolveAndSaveDid(did)
    }

    // MARK: - 展示模型

    public func generateDid(_ did: String) async -> Did? {
        guard let entity = try? await core.getDidDocument(did),
              let root = DidJson.parseObject(entity.doc) else { return nil }
        let created = Json.readString(root, "created", default: "")
        let updated = Json.readString(root, "updated", default: "")
        let verificationMethods = self.readJsonArray(root, "verificationMethod").compactMap { element -> VerificationMethod? in
            guard let item = element as? [String: Any] else { return nil }
            return VerificationMethod(
                id: DidJson.optString(item, "id"),
                controller: DidJson.optString(item, "controller"),
                type: DidJson.optString(item, "type"),
                publicKeyBase58: DidJson.optString(item, "publicKeyBase58"),
                isSelf: DidJson.optString(item, "controller").caseInsensitiveCompare(did) == .orderedSame
            )
        }
        return Did(id: did, created: Self.formatUtc(created), updated: Self.formatUtc(updated), verificationMethods: verificationMethods)
    }

    public func generateProfileVC(_ did: String) async -> ProfileVC? {
        guard let entity = try? await core.getDidDocument(did),
              let root = DidJson.parseObject(entity.doc) else { return nil }
        let profile = self.getProfile(root)
        let credentials = DidJson.optArray(root, "credentials") ?? []
        var nft: Nft?
        if let profile {
            if let vc = self.findCredentialById(credentials, profile.preferredAvatar) {
                nft = await self.generateAvatarNft(vc)
            }
        }
        if let nft, !nft.hasLocal, !nft.uri.isEmpty {
            _ = await self.nft?.fetchAndCacheNftMeta(contract: nft.contract, tokenId: nft.tokenId, tokenUri: nft.uri)
        }
        return ProfileVC(
            nickname: profile?.nickname ?? "",
            bio: "",
            createdTime: nft?.issuanceDate ?? "",
            nft: nft
        )
    }

    public func generateSwtcNft(_ vc: String) async -> Nft? {
        await self.generateSwtcNft(DidJson.parseObject(vc) ?? [:], vc: vc)
    }

    private func generateSwtcNft(_ root: [String: Any], vc: String) async -> Nft? {
        if let nft = await self.avatarResolver?.resolveSwtcAvatar(vc: vc) {
            return nft
        }
        if let nft = await self.nft?.resolveSwtcAvatar(vc: vc) {
            return nft
        }
        return self.buildSwtcNft(root)
    }

    public func generateEthrNft(_ vc: String) async -> Nft? {
        await self.generateEthrNft(DidJson.parseObject(vc) ?? [:], vc: vc)
    }

    private func generateEthrNft(_ root: [String: Any], vc: String) async -> Nft? {
        if let nft = await self.avatarResolver?.resolveEthrAvatar(vc: vc) {
            return nft
        }
        if let nft = await self.nft?.resolveEthrAvatar(vc: vc) {
            return nft
        }
        return self.buildEthrNft(root)
    }

    public func getAvatarNftCredentials(account: WalletAccount) async -> [DidAvatarCredential] {
        let ownerDid = self.toDid(account)
        guard !ownerDid.isEmpty else { return [] }
        let candidates: [DidAvatarAsset] = if let source = self.avatarCredentialSource {
            await source.getAvatarCandidates(account: account)
        } else if let nft = self.nft {
            await nft.getAvatarCandidates(account: account)
        } else {
            []
        }
        return candidates.map { self.buildAvatarCredential(ownerDid: ownerDid, asset: $0) }
    }

    // MARK: - DApp 签名面（SwiftDappConnect.DidSDK）

    public func didGenerateBase58PublicKey(privateKey: String) async throws -> (publicKeyBase58: String, type: String) {
        let result: GenerateBase58PKResult = try await bridge.callAs(method: "generatePublicKeyBase58", params: ["privateKey": privateKey], as: GenerateBase58PKResult.self)
        return (result.publicKeyBase58, result.type)
    }

    /// 只校验 VC 结构（M-15 三条 + keyDoc 两条，见 Did-Swift 04 坑 #19）；用户确认由宿主 UI 完成。
    public func signCredential(privateKey: String, vcJson: String) async throws -> String {
        guard let object = DidJson.parseObject(vcJson) else { throw SwiftDidError.invalidPayload }
        guard let credential = DidJson.optDict(object, "credential"),
              credential["@context"] != nil || credential["type"] != nil,
              credential["credentialSubject"] != nil,
              credential["issuer"] != nil || object["issuerObject"] != nil
        else { throw SwiftDidError.invalidCredential }
        // JS signCredential 强依赖 keyDoc.did / keyDoc.id（见 Did-Swift 03 §2）
        guard let keyDoc = DidJson.optDict(object, "keyDoc"),
              !(DidJson.optString(keyDoc, "did").isEmpty),
              !(DidJson.optString(keyDoc, "id").isEmpty)
        else { throw SwiftDidError.invalidCredential }
        var params = object
        params["privateKey"] = privateKey
        return try await self.bridge.call(method: "signCredential", params: params)
    }

    public func ipfsGetPublicKey(privateKey: String) async throws -> String {
        try await self.bridge.call(method: "ipfsGetPublicKey", params: ["privateKey": privateKey])
    }

    public func ipfsPersonalSign(privateKey: String, data: [Int]) async throws -> String {
        try await self.bridge.call(method: "ipfsPersonalSign", params: ["privateKey": privateKey, "data": data])
    }

    // MARK: - 写操作（发布链，见 Did-Swift 01 §3.4）

    public func uploadInitialDidDoc(privateKey: String, did: String, nickname: String = "") async -> Bool {
        do {
            let keyResult: GenerateBase58PKResult = try await bridge.callAs(method: "generatePublicKeyBase58", params: ["privateKey": privateKey], as: GenerateBase58PKResult.self)
            // didStat 失败 = 发布失败（Swift 修正 #2，不重试）
            guard let previousCid = await self.readDidStatCid(did) else { return false }

            let didDoc: [String: Any] = [
                "version": "1.0.0",
                "verificationMethods": [
                    [
                        "id": "\(did)#key-1",
                        "type": keyResult.type,
                        "controller": did,
                        "publicKeyBase58": keyResult.publicKeyBase58
                    ]
                ],
                "assertionMethods": ["\(did)#key-1"],
                "authentications": ["\(did)#key-1"],
                "services": [
                    [
                        "id": "\(did)#profile",
                        "type": "Profile",
                        "serviceEndpoint": ["nickname": nickname, "preferredAvatar": ""]
                    ],
                    [
                        "id": "\(did)#ipfs-storage",
                        "type": "IpfsStorage",
                        "serviceEndpoint": [
                            "ipns": "ipns://k2k4r8ntjlp1cmgped39eq1fi4yze6fsr8og1kcmjhamgs3ubwkfldei"
                        ].merging(previousCid.isEmpty ? [:] : ["previousCid": previousCid]) { _, new in new }
                    ]
                ],
                "credentials": [Any](),
                "did": did
            ]

            let generated = try await bridge.call(method: "generateDidDoc", params: didDoc)
            let didDocJson = self.ensureCredentialsArrayInDidDocument(generated)
            let res: PublishDidResult = try await bridge.callAs(method: "publishDid", params: ["did": did, "privateKey": privateKey, "didDocument": didDocJson], as: PublishDidResult.self)
            if res.code == "0" {
                try await self.core.saveNewCreatedDid(did, doc: didDocJson)
                return true
            }
            return false
        } catch {
            return false
        }
    }

    public func updateDidNickname(privateKey: String, did: String, nickname: String, currentDoc: String) async -> Bool {
        do {
            guard let doc = try await self.resolveBaseDoc(did, currentDoc) else { return false }
            var json = doc
            let services = DidDocumentEditor.services(from: json)
            let previousCid = await self.readDidStatCid(did)
            guard previousCid != nil else { return false } // didStat 失败 → 中止发布
            let updatedServices = services.map { element -> Any in
                guard let service = element as? [String: Any] else { return element }
                switch DidJson.optString(service, "type") {
                case "Profile":
                    return DidDocumentEditor.profileService(
                        did: did,
                        nickname: nickname,
                        preferredAvatar: DidJson.readProfileField(json, "preferredAvatar") ?? ""
                    )
                case "IpfsStorage":
                    return DidDocumentEditor.serviceWithPreviousCid(did: did, service: service, previousCid: previousCid)
                default:
                    return service
                }
            }
            DidDocumentEditor.setServices(updatedServices, on: &json)
            let (ok, _) = await self.publishEditedDocument(did: did, privateKey: privateKey, json: &json) { d, doc in
                try await self.core.saveNewNicknameDid(d, doc: doc)
            }
            return ok
        } catch {
            return false
        }
    }

    public func updateDidAvatar(privateKey: String, did: String, currentDoc: String, selectedAvatar: DidAvatarCredential) async -> Bool {
        do {
            guard let doc = try await self.resolveBaseDoc(did, currentDoc) else { return false }
            var json = doc
            let services = DidDocumentEditor.services(from: json)
            let previousCid = await self.readDidStatCid(did)
            guard previousCid != nil else { return false }
            let vcJson = try await self.generateAvatarVc(privateKey: privateKey, did: did, selectedAvatar: selectedAvatar)
            let updatedServices = services.map { element -> Any in
                guard let service = element as? [String: Any] else { return element }
                switch DidJson.optString(service, "type") {
                case "Profile":
                    return DidDocumentEditor.profileService(
                        did: did,
                        nickname: DidJson.readProfileField(json, "nickname") ?? "",
                        preferredAvatar: selectedAvatar.credentialId
                    )
                case "IpfsStorage":
                    return DidDocumentEditor.serviceWithPreviousCid(did: did, service: service, previousCid: previousCid)
                default:
                    return service
                }
            }
            let credentials = DidJson.optArray(json, "credentials") ?? []
            var updatedCredentials = credentials.filter { element in
                guard let cred = element as? [String: Any] else { return true }
                return DidJson.optString(cred, "id").caseInsensitiveCompare(selectedAvatar.credentialId) != .orderedSame
            }
            updatedCredentials.append(DidJson.parseObject(vcJson) ?? [:])
            DidDocumentEditor.setServices(updatedServices, on: &json)
            json["credentials"] = updatedCredentials
            let (ok, _) = await self.publishEditedDocument(did: did, privateKey: privateKey, json: &json) { d, doc in
                try await self.core.saveNewAvatarDid(d, doc: doc)
            }
            return ok
        } catch {
            return false
        }
    }

    public func publishDidDelete(privateKey: String, did: String) async -> Bool {
        do {
            let res = try await self.publishDid(did: did, privateKey: privateKey, didDocument: "{}")
            if res.code == "0" {
                let doc = try? await core.getDidDocument(did)?.doc
                try await self.core.deleteDidDocument(did, deletedDoc: doc)
                return true
            }
            return false
        } catch {
            return false
        }
    }

    public func addCredentialToDid(privateKey: String, did: String, currentDoc: String, credentialData: UnifiedNftCredentialData) async -> DidWriteResult {
        do {
            guard credentialData.ownerDid == did else { throw SwiftDidError.invalidPayload }
            try DidCredentialHelper.validateCredentialData(credentialData)
            guard let doc = try await self.resolveBaseDoc(did, currentDoc) else { return DidWriteResult(success: false) }
            let vcId = DidCredentialHelper.generateVcId(credentialData)
            let vcJson = try await self.generateNftVc(privateKey: privateKey, ownerDid: did, credentialData: credentialData)
            var json = doc
            let credentials = DidDocumentEditor.credentials(from: json)
            json["credentials"] = DidDocumentEditor.upsertCredential(
                credentials, incoming: DidJson.parseObject(vcJson) ?? [:], byId: vcId
            )
            guard await self.applyPreviousCid(&json, did: did) else { return DidWriteResult(success: false) }
            let (ok, finalDoc) = await self.publishEditedDocument(did: did, privateKey: privateKey, json: &json) { d, doc in
                try await self.core.saveDidDocument(d, doc: doc)
            }
            return DidWriteResult(success: ok, didDocument: finalDoc)
        } catch {
            return DidWriteResult(success: false)
        }
    }

    public func deleteCredentialFromDid(privateKey: String, did: String, currentDoc: String, credentialId: String) async -> DidWriteResult {
        do {
            guard !credentialId.isEmpty else { throw SwiftDidError.invalidPayload }
            guard let doc = try await self.resolveBaseDoc(did, currentDoc) else { return DidWriteResult(success: false) }
            var json = doc
            let credentials = DidDocumentEditor.credentials(from: json)
            guard let updatedCredentials = DidDocumentEditor.removingCredential(credentials, byId: credentialId) else {
                return DidWriteResult(success: false)
            }
            json["credentials"] = updatedCredentials
            DidDocumentEditor.setServices(
                DidCredentialHelper.clearPreferredAvatarIfMatches(DidDocumentEditor.services(from: json), credentialId),
                on: &json
            )
            guard await self.applyPreviousCid(&json, did: did) else { return DidWriteResult(success: false) }
            let (ok, finalDoc) = await self.publishEditedDocument(did: did, privateKey: privateKey, json: &json) { d, doc in
                try await self.core.saveDidDocument(d, doc: doc)
            }
            return DidWriteResult(success: ok, didDocument: finalDoc)
        } catch {
            return DidWriteResult(success: false)
        }
    }

    public func queryAndValidateVcid(_ vcid: String) async -> QueryVcidResult {
        guard !vcid.isEmpty else { return QueryVcidResult(isValid: false) }
        let ownerDid = DidCredentialHelper.ownerDidFromCredentialId(vcid)
        guard !ownerDid.isEmpty else { return QueryVcidResult(isValid: false) }
        guard let ownerDoc = await self.resolveOwnerDidDocument(ownerDid) else { return QueryVcidResult(isValid: false) }
        let credentials = DidCredentialHelper.readCredentials(ownerDoc)
        let matchedIndex = DidCredentialHelper.findCredentialIndex(credentials, vcid)
        guard matchedIndex >= 0, let matched = credentials[matchedIndex] as? [String: Any] else { return QueryVcidResult(isValid: false) }
        let credentialJson = DidJson.stringify(matched)
        let verifyResult = await (try? self.verifyCredential(credentialJson)) ?? CredentialVerificationResult(verified: false)
        return QueryVcidResult(isValid: verifyResult.verified, credential: credentialJson)
    }

    public func bindVcidToDid(privateKey: String, did: String, currentDoc: String, credentialJson: String) async -> DidWriteResult {
        do {
            guard !credentialJson.isEmpty else { throw SwiftDidError.invalidPayload }
            guard let incoming = DidJson.parseObject(credentialJson) else { throw SwiftDidError.invalidPayload }
            let credentialId = DidJson.optString(incoming, "id")
            guard !credentialId.isEmpty else { throw SwiftDidError.invalidPayload }
            let vcResult = try await self.verifyCredential(credentialJson)
            guard vcResult.verified else { throw SwiftDidError.invalidCredential }
            guard let doc = try await self.resolveBaseDoc(did, currentDoc) else { return DidWriteResult(success: false) }
            var json = doc
            let credentials = DidDocumentEditor.credentials(from: json)
            json["credentials"] = DidDocumentEditor.upsertCredential(credentials, incoming: incoming, byId: credentialId)
            guard await self.applyPreviousCid(&json, did: did) else { return DidWriteResult(success: false) }
            let (ok, finalDoc) = await self.publishEditedDocument(did: did, privateKey: privateKey, json: &json) { d, doc in
                try await self.core.saveDidDocument(d, doc: doc)
            }
            return DidWriteResult(success: ok, didDocument: finalDoc)
        } catch {
            return DidWriteResult(success: false)
        }
    }

    public func updatePreferredAvatar(privateKey: String, did: String, currentDoc: String, credentialId: String) async -> DidWriteResult {
        do {
            guard !credentialId.isEmpty else { throw SwiftDidError.invalidPayload }
            guard let doc = try await self.resolveBaseDoc(did, currentDoc) else { return DidWriteResult(success: false) }
            let credentials = DidDocumentEditor.credentials(from: doc)
            let found = credentials.contains { element in
                (element as? [String: Any]).map { DidJson.optString($0, "id") == credentialId } ?? false
            }
            guard found else { throw SwiftDidError.invalidPayload }
            var json = doc
            let services = DidDocumentEditor.services(from: json)
            let updatedServices = services.map { element -> Any in
                guard let service = element as? [String: Any] else { return element }
                if DidJson.optString(service, "type") == "Profile" {
                    return DidDocumentEditor.profileService(
                        did: did,
                        nickname: DidJson.readProfileField(json, "nickname") ?? "",
                        preferredAvatar: credentialId
                    )
                }
                return service
            }
            DidDocumentEditor.setServices(updatedServices, on: &json)
            guard await self.applyPreviousCid(&json, did: did) else { return DidWriteResult(success: false) }
            let (ok, finalDoc) = await self.publishEditedDocument(did: did, privateKey: privateKey, json: &json) { d, doc in
                try await self.core.saveNewAvatarDid(d, doc: doc)
            }
            return DidWriteResult(success: ok, didDocument: finalDoc)
        } catch {
            return DidWriteResult(success: false)
        }
    }

    // MARK: - VC 校验

    public func verifyCredential(_ credentialJson: String) async throws -> CredentialVerificationResult {
        guard !credentialJson.isEmpty, let credential = DidJson.parseObject(credentialJson) else {
            throw SwiftDidError.invalidPayload
        }
        let expirationDate = DidJson.optString(credential, "expirationDate")
        if !expirationDate.isEmpty {
            // P0-6：非空但无法解析的 expirationDate（攻击者可控字段）不得跳过过期检查——fail-closed。
            // 与 DidJson.parseISO8601 的「解析失败 = 无法比较」契约一致：present-but-malformed 视为校验失败。
            guard let date = DidJson.parseISO8601(expirationDate) else {
                return CredentialVerificationResult(verified: false, errorKind: "invalidExpirationDate")
            }
            if date < Date() {
                return CredentialVerificationResult(verified: false)
            }
        }
        if DidCredentialHelper.credentialIncludesType(credentialJson, DidCredentialHelper.vcTypeUsageAuthorization) {
            if await (self.checkGranteeCredentialUpdate(credentialJson)).isUpdate {
                return CredentialVerificationResult(verified: false)
            }
        }
        let raw = try await bridge.call(method: "verifyCredential", params: ["credential": credentialJson])
        guard let result = DidJson.parseObject(raw) else { return CredentialVerificationResult(verified: false) }
        // Swift 增强：保留 errorKind / error（Kotlin 丢弃，见 Did-Swift 04 坑 #21）
        return CredentialVerificationResult(
            verified: DidJson.optString(result, "verified") == "true",
            results: DidJson.optArray(result, "results").map { DidJson.stringify($0) },
            errorKind: DidJson.optString(result, "errorKind").nilIfBlank,
            error: DidJson.optString(result, "error").nilIfBlank
        )
    }

    public func checkGranteeCredentialUpdate(_ credentialJson: String) async -> GranteeCredentialUpdateResult {
        guard let credential = DidJson.parseObject(credentialJson) else {
            return GranteeCredentialUpdateResult(isUpdate: true, credential: nil, fetchFailed: true)
        }
        let credentialId = DidJson.optString(credential, "id")
        let ownerDid = DidCredentialHelper.ownerDidFromCredentialId(credentialId)
        guard !ownerDid.isEmpty else { return GranteeCredentialUpdateResult(isUpdate: true) }
        guard let ownerDoc = await self.resolveOwnerDidDocument(ownerDid) else {
            return GranteeCredentialUpdateResult(isUpdate: true, credential: nil, fetchFailed: true)
        }
        let credentials = DidCredentialHelper.readCredentials(ownerDoc)
        let matchedIndex = DidCredentialHelper.findCredentialIndex(credentials, credentialId)
        guard matchedIndex >= 0, let matched = credentials[matchedIndex] as? [String: Any] else {
            return GranteeCredentialUpdateResult(isUpdate: true)
        }
        let matchedJson = DidJson.stringify(matched)
        let originalSubjectId = DidJson.optDict(credential, "credentialSubject").map { DidJson.optString($0, "id") }
        let matchedSubjectId = DidJson.optDict(matched, "credentialSubject").map { DidJson.optString($0, "id") }
        if originalSubjectId != matchedSubjectId {
            return GranteeCredentialUpdateResult(isUpdate: true, credential: matchedJson)
        }
        if DidJson.optString(matched, "expirationDate") != DidJson.optString(credential, "expirationDate") {
            return GranteeCredentialUpdateResult(isUpdate: true, credential: matchedJson)
        }
        return GranteeCredentialUpdateResult(isUpdate: false, credential: matchedJson)
    }

    // MARK: - NFT 元数据透传（对齐 Kotlin DidSdk 10 签名 = 9 方法名 + resolveCredentialImage 重载）

    public func resolveCredentialImage(_ imageUrl: String?, metadataUri: String?) async -> String? {
        await self.nft?.resolveCredentialImage(imageUrl, metadataUri: metadataUri)
    }

    public func resolveCredentialImage(_ request: CredentialImageRequest) async -> ResolvedCredentialImage? {
        await self.nft?.resolveCredentialImage(request)
    }

    public func resolveCredentialImages(_ requests: [CredentialImageRequest]) async -> [ResolvedCredentialImage?] {
        await self.nft?.resolveCredentialImages(requests) ?? []
    }

    public func fetchResolvedMetadataImage(_ metadataUrl: String) async -> String? {
        await self.nft?.fetchResolvedMetadataImage(metadataUrl)
    }

    public func normalizeAssetUrl(_ rawUrl: String?, baseUrl: String?) -> String? {
        self.nft?.normalizeAssetUrl(rawUrl, baseUrl: baseUrl)
    }

    public func extractResolvedMetadataImageUrl(_ metadataBody: String, metadataUri: String) -> String? {
        self.nft?.extractResolvedMetadataImageUrl(metadataBody, metadataUri: metadataUri)
    }

    public func isSupportedRemoteAssetUrl(_ url: String?) -> Bool {
        self.nft?.isSupportedRemoteAssetUrl(url) ?? false
    }

    public func extractSwtcMetadataUri(_ tokenInfosPayload: String?) -> String? {
        self.nft?.extractSwtcMetadataUri(tokenInfosPayload)
    }

    /// 门面层返回 Optional（镜像 Kotlin `DidSdk` 包装方法）；协议缝 `DidNftResolution` 为非 Optional（对齐 NftSdk），
    /// 属对 DidSdk 包装层的显式偏离（见 Nft-Swift 04 坑 #5）。
    public func fetchMetadataFields(_ metadataUri: String) async -> NftMetadataFields? {
        await self.nft?.fetchMetadataFields(metadataUri)
    }

    public func ensureSwtcCredentialMetadata(_ vc: String) async {
        await self.nft?.ensureSwtcCredentialMetadata(vc)
    }

    private func readJsonArray(_ root: [String: Any], _ key: String) -> [Any] {
        if let array = DidJson.optArray(root, key) {
            return array
        }
        let alias: String
        switch key {
        case "service": alias = "services"
        case "verificationMethod": alias = "verificationMethods"
        default: return []
        }
        return DidJson.optArray(root, alias) ?? []
    }

    private func findCredentialById(_ credentials: [Any], _ id: String) -> String? {
        let index = DidCredentialHelper.findCredentialIndex(credentials, id)
        guard index >= 0, let object = credentials[index] as? [String: Any] else { return nil }
        return DidJson.stringify(object)
    }

    private func isSwtcAvatarVc(_ root: [String: Any]) -> Bool {
        switch Json.readString(root, "credentialSubject.standard")?.lowercased() {
        case "jingtumnft": return true
        case "erc-721": return false
        default: break
        }
        let nftIssuer = Json.readString(root, "credentialSubject.nftIssuer", default: "")
        let contractAddress = Json.readString(root, "credentialSubject.contractAddress", default: "")
        return !nftIssuer.isEmpty && contractAddress.isEmpty
    }

    private func generateAvatarNft(_ vc: String) async -> Nft? {
        let root = DidJson.parseObject(vc) ?? [:]
        if self.isSwtcAvatarVc(root) {
            return await self.generateSwtcNft(root, vc: vc)
        }
        return await self.generateEthrNft(root, vc: vc)
    }

    private func buildSwtcNft(_ root: [String: Any]) -> Nft? {
        let tokenId = Json.readString(root, "credentialSubject.tokenId", default: "")
        let nftIssuer = Json.readString(root, "credentialSubject.nftIssuer", default: "")
        let tokenName = Json.readString(root, "credentialSubject.tokenName", default: "")
        let issuance = Json.readString(root, "issuanceDate", default: "")
        return Nft(contract: nftIssuer, tokenId: tokenId, name: tokenName, uri: "",
                   issuanceDate: issuance, image: nil, hasLocal: false, chainId: nil)
    }

    private func buildEthrNft(_ root: [String: Any]) -> Nft? {
        let tokenId = Json.readString(root, "credentialSubject.tokenId", default: "")
        let contract = Json.readString(root, "credentialSubject.contractAddress", default: "")
        let chainId = Json.readLong(root, "credentialSubject.chainId", default: 0)
        let issuance = Json.readString(root, "issuanceDate", default: "")
        return Nft(contract: contract, tokenId: tokenId, name: "", uri: "",
                   issuanceDate: issuance, image: nil, hasLocal: false, chainId: chainId)
    }

    private func buildAvatarCredential(ownerDid: String, asset: DidAvatarAsset) -> DidAvatarCredential {
        let credentialId = DidCredentialHelper.buildAvatarCredentialId(ownerDid: ownerDid, asset: asset)
        if asset.isSwtc {
            return DidAvatarCredential(
                credentialId: credentialId, image: asset.image, name: asset.name,
                contract: asset.issuer, tokenId: asset.tokenId, issuer: asset.issuer,
                tokenName: asset.tokenName, chainId: nil, isSwtc: true, ownerDid: ownerDid
            )
        }
        let checksumContract = ChecksumUtils.toChecksumAddress(asset.contract, or: "")
        return DidAvatarCredential(
            credentialId: credentialId, image: asset.image, name: asset.name,
            contract: checksumContract, tokenId: asset.tokenId, issuer: checksumContract,
            tokenName: asset.tokenName, chainId: asset.chainId, isSwtc: false, ownerDid: ownerDid
        )
    }

    // MARK: - 内部：发布链

    private func resolveBaseDoc(_ did: String, _ currentDoc: String) async throws -> [String: Any]? {
        if !currentDoc.isEmpty {
            return DidJson.parseObject(currentDoc)
        }
        let chainDoc = await (try? self.resolver.resolve(did)) ?? ""
        if !chainDoc.isEmpty, !DidJson.isMissingDidDocument(chainDoc), let parsed = DidJson.parseObject(chainDoc) {
            return parsed
        }
        guard let local = try? await core.getDidDocument(did), !DidJson.isMissingDidDocument(local.doc) else { return nil }
        return DidJson.parseObject(local.doc)
    }

    private func resolveOwnerDidDocument(_ ownerDid: String) async -> String? {
        switch await self.resolveDid(ownerDid) {
        case let .document(doc) where !DidJson.isMissingDidDocument(doc):
            return doc
        case .missing, .error, .document:
            break
        }
        guard let local = try? await core.getDidDocument(ownerDid), !DidJson.isMissingDidDocument(local.doc) else { return nil }
        return local.doc
    }

    private func publishDid(did: String, privateKey: String, didDocument: String) async throws -> PublishDidResult {
        try await self.bridge.callAs(
            method: "publishDid",
            params: ["did": did, "privateKey": privateKey, "didDocument": didDocument],
            as: PublishDidResult.self
        )
    }

    /// 返回 nil = didStat 调用失败（不重试，发布应中止，见 Did-Swift 01 §6）；"" = 成功但无 previousCid。
    private func readDidStatCid(_ did: String) async -> String? {
        guard let result: DidStatResult = try? await bridge.callAs(
            method: "didStat", params: ["did": did], as: DidStatResult.self
        ) else {
            return nil
        }
        return result.cid ?? ""
    }

    /// 失败返回 false（didStat 失败 → 中止发布，不静默继续）。
    private func applyPreviousCid(_ json: inout [String: Any], did: String) async -> Bool {
        guard let previousCid = await self.readDidStatCid(did) else { return false }
        guard !previousCid.isEmpty else { return true }
        let services = DidDocumentEditor.services(from: json)
        let updatedServices: [Any] = services.map { element in
            guard let service = element as? [String: Any] else { return element }
            return DidDocumentEditor.serviceWithPreviousCid(did: did, service: service, previousCid: previousCid)
        }
        DidDocumentEditor.setServices(updatedServices, on: &json)
        return true
    }

    /// 发布已编辑 DID 文档的收尾：set `updated` → 删 `did` 键 → publish → 成功后落库。
    /// `save` 仅在 publish 成功（code == "0"）时调用；返回 (成功, 最终文档)。
    /// 闭包不标 @MainActor：调用点（门面 @MainActor 上下文）创建的闭包自然继承 MainActor 隔离，
    /// 落库调用（core 亦 @MainActor）无需额外标注（见 review 优化 #3）。
    private func publishEditedDocument(
        did: String,
        privateKey: String,
        json: inout [String: Any],
        save: @escaping (String, String) async throws -> Void
    ) async -> (success: Bool, didDocument: String?) {
        json["updated"] = DidJson.nowISO()
        json.removeValue(forKey: "did")
        do {
            let res = try await self.publishDid(did: did, privateKey: privateKey, didDocument: DidJson.stringify(json))
            guard res.code == "0" else { return (false, nil) }
            let finalDoc = DidJson.stringify(json)
            try await save(did, finalDoc)
            return (true, finalDoc)
        } catch {
            return (false, nil)
        }
    }

    private func generateAvatarVc(privateKey: String, did: String, selectedAvatar: DidAvatarCredential) async throws -> String {
        try await self.generateNftVc(
            privateKey: privateKey,
            ownerDid: did,
            credentialData: DidCredentialHelper.fromAvatarCredential(ownerDid: did, avatar: selectedAvatar)
        )
    }

    private func generateNftVc(privateKey: String, ownerDid: String, credentialData: UnifiedNftCredentialData) async throws -> String {
        try await self.bridge.call(method: "generateVC", params: self.buildGenerateVcParams(privateKey: privateKey, ownerDid: ownerDid, credentialData: credentialData))
    }

    private func buildGenerateVcParams(privateKey: String, ownerDid: String, credentialData: UnifiedNftCredentialData) -> [String: Any] {
        do {
            try DidCredentialHelper.validateCredentialData(credentialData)
        } catch {
            return [:]
        }
        return [
            "id": DidCredentialHelper.generateVcId(credentialData),
            "types": DidCredentialHelper.vcTypesFor(credentialData),
            "subject": DidCredentialHelper.buildNftSubject(credentialData),
            "privateKey": privateKey,
            "address": String(ownerDid.split(separator: ":").last ?? ""),
            "did": ownerDid,
            "expirationDate": DidJson.nowISO(offsetMillis: credentialData.expirationDurationMs),
            "contextType": DidCredentialHelper.contextTypeFor(credentialData)
        ]
    }

    func ensureCredentialsArrayInDidDocument(_ didDocJson: String) -> String {
        guard var json = DidJson.parseObject(didDocJson) else { return didDocJson }
        if json["credentials"] == nil {
            json["credentials"] = [Any]()
        }
        return DidJson.stringify(json)
    }

    // MARK: - 内部小工具

    static func formatUtc(_ utc: String) -> String {
        guard !utc.isEmpty else { return "" }
        guard let date = DidJson.parseISO8601(utc) else { return utc }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // 值类型 Calendar 免 DateFormatter 每次分配 + 无 Sendable/locale 隐患（见 review 优化 #11）。
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
            comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0
        )
    }
}
