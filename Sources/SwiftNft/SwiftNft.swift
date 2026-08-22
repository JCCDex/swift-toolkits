import Foundation
import OSLog
import SwiftCore

// MARK: - DidNftResolution（协议缝，阶段二形态）

/// 头像/NFT 解析能力（宿主可注入；`SwiftNft` 为其实现，SwiftDid 阶段二以
/// `public typealias DidNftResolution = SwiftNft.DidNftResolution` 保持公开拼写——见 Nft-Swift 02 §2）。
///
/// 覆盖 Kotlin `NftSdk` 的完整方法面（14 个公开方法 = 13 个方法名 + `resolveCredentialImage` 重载，
/// 含 `fetchAndCacheNftMeta`）。纯数据取/解析（无 UI），不加 @MainActor（自由线程调度）。
public protocol DidNftResolution: AnyObject, Sendable {
    func resolveSwtcAvatar(vc: String) async -> Nft?
    func resolveEthrAvatar(vc: String) async -> Nft?
    func getAvatarCandidates(account: WalletAccount) async -> [DidAvatarAsset]
    func fetchAndCacheNftMeta(contract: String, tokenId: String, tokenUri: String) async -> NftMeta?
    func resolveCredentialImage(_ imageUrl: String?, metadataUri: String?) async -> String?
    func resolveCredentialImage(_ request: CredentialImageRequest) async -> ResolvedCredentialImage?
    func resolveCredentialImages(_ requests: [CredentialImageRequest]) async -> [ResolvedCredentialImage?]
    func fetchResolvedMetadataImage(_ metadataUrl: String) async -> String?
    func normalizeAssetURL(_ rawUrl: String?, baseUrl: String?) -> String?
    func extractResolvedMetadataImageURL(_ metadataBody: String, metadataUri: String) -> String?
    func isSupportedRemoteAssetURL(_ url: String?) -> Bool
    func extractSwtcMetadataUri(_ tokenInfosPayload: String?) -> String?
    func fetchMetadataFields(_ metadataUri: String) async -> NftMetadataFields
    func ensureSwtcCredentialMetadata(_ vc: String) async
}

// MARK: - NftClient 门面（镜像 Kotlin NftSdk 14 方法）

//
// 类名取 `NftClient` 而非 `SwiftNft`：模块 SwiftNft + 类 SwiftNft 同名会让
// `SwiftNft.Nft` 这类**模块限定**引用解析到类（实测 `'Nft' is not a member type of class`），
// 见 review 四、架构层观察 #4；改名后模块名不再被遮蔽。

/// 门面：自由线程（非 @MainActor，对齐 `DidNftResolution` 协议缝）。
/// 解析/编排逻辑在此（Kotlin 在 NftStore 内实现；Swift 让 NftStore 保持纯存储，见 02 §5）。
public final class NftClient: DidNftResolution, Sendable {
    // 配置拆为成员变量（不持有 SwiftNftConfig 单一对象）：
    private let store: any NftStore
    private let ipfsGateway: String // 贯穿所有 ipfs→网关重写（normalizedGateway 已保证尾部 `/`）
    private let httpClient: any NftHttpClient
    private let ethTokenUriResolver: (any IEthTokenUriResolver)? // EVM tokenURI（模块默认 EthTokenUriResolver）
    private let swtcTokenUriResolver: (any ISwtcTokenUriResolver)? // 宿主注入；nil = SWTC 元数据解析不可用

    private let imageCache = AsyncMemoCache()
    private let logger = Logger(subsystem: "com.jccdex.toolkits.swiftnft", category: "SwiftNft")

    public init(config: SwiftNftConfig) {
        // 网关校验：注入的 ipfsGateway 必须 http/https（normalizedGateway 已保证尾部 `/`）。
        // 非法值回退默认网关，而非 precondition crash 宿主（配置错误不应崩 App）。
        let originalGateway = config.ipfsGateway
        var resolved = config
        let lower = resolved.ipfsGateway.lowercased()
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
            resolved.ipfsGateway = IpfsResolver.defaultGateway
        }
        self.store = resolved.store
        self.ipfsGateway = resolved.ipfsGateway
        self.httpClient = resolved.httpClient
        self.ethTokenUriResolver = resolved.ethTokenUriResolver
        self.swtcTokenUriResolver = resolved.swtcTokenUriResolver
        // 与「原始配置」比较（旧实现对已回退的 resolved 再比较恒 false，告警永不触发）
        if resolved.ipfsGateway != originalGateway {
            self.logger.warning("SwiftNft: ipfsGateway 非法（非 http/https），已回退默认网关")
        }
    }

    // MARK: - 头像解析与候选（对齐 NftSdk 3.1）

    public func getAvatarCandidates(account: WalletAccount) async -> [DidAvatarAsset] {
        // 观察流（AsyncStream）不 throw：store 读取失败会被 GRDB 流吞掉，故此处无需 do/catch（catch 不可达）。
        if account.chain == .swtc {
            let rows = await self.store.observeSwtcNfts(ownerAddress: account.address).firstValue() ?? []
            return rows.map { entity in
                let tokenName = isBlank(entity.fundCodeName) ? entity.fundCode : entity.fundCodeName
                return DidAvatarAsset(
                    image: entity.image,
                    name: entity.name ?? tokenName,
                    contract: entity.issuer,
                    tokenId: entity.tokenId,
                    issuer: entity.issuer,
                    tokenName: tokenName,
                    chainId: nil,
                    isSwtc: true
                )
            }
        } else {
            guard let chainId = account.chain.evmChainId else { return [] }
            let chainIdHex = "0x" + String(chainId, radix: 16)
            let rows = await self.store.observeAllEvmNftItems(chainId: chainIdHex, ownerAddress: account.address).firstValue() ?? []
            return rows.map { entity in
                DidAvatarAsset(
                    image: entity.imageUrl,
                    name: entity.title ?? "",
                    contract: entity.contractAddress,
                    tokenId: entity.tokenId,
                    issuer: nil,
                    tokenName: entity.title,
                    chainId: chainId,
                    isSwtc: false
                )
            }
        }
    }

    public func resolveSwtcAvatar(vc: String) async -> Nft? {
        guard let root = self.parseVc(vc) else { return nil }
        let tokenId = Json.readString(root, "credentialSubject.tokenId", default: "")
        let nftIssuer = Json.readString(root, "credentialSubject.nftIssuer", default: "")
        let tokenName = Json.readString(root, "credentialSubject.tokenName", default: "")
        let issuance = Json.readString(root, "issuanceDate", default: "")
        guard !tokenId.isEmpty, !nftIssuer.isEmpty else { return nil }

        do {
            // 1) nft_meta 命中
            if let localMeta = try await self.store.nftMeta(contract: nftIssuer, tokenId: tokenId),
               let nft = await buildSwtcNftFromMeta(nftIssuer: nftIssuer, tokenId: tokenId,
                                                    tokenName: tokenName, issuance: issuance, meta: localMeta) {
                return nft
            }
            // 2) swtc_nfts 行命中（image 或 metadataUri 非空）
            if let swtcNft = try await self.store.swtcNftByIssuerAndTokenId(issuer: nftIssuer, tokenId: tokenId) {
                let resolvedUri = self.sanitizeUri(normalizeRemoteAssetURL(swtcNft.metadataUri, baseUrl: nil, gateway: self.ipfsGateway))
                if !isBlank(swtcNft.image) || !resolvedUri.isEmpty {
                    return await Nft(
                        contract: nftIssuer,
                        tokenId: tokenId,
                        name: swtcNft.name ?? tokenName,
                        uri: resolvedUri,
                        issuanceDate: issuance,
                        image: self.resolveRemoteImageURL(swtcNft.image, resolvedUri),
                        hasLocal: !isBlank(swtcNft.image), // 修正 Kotlin image != null（空串也算 true）
                        chainId: nil
                    )
                }
            }
            // 3) 链上 erc_info 拉取并缓存
            if let cachedMeta = await resolveAndCacheSwtcNftMeta(nftIssuer: nftIssuer, tokenId: tokenId),
               let nft = await buildSwtcNftFromMeta(nftIssuer: nftIssuer, tokenId: tokenId,
                                                    tokenName: tokenName, issuance: issuance, meta: cachedMeta) {
                return nft
            }
            // 4) 兜底裸 Nft
            return Nft(contract: nftIssuer, tokenId: tokenId, name: tokenName, uri: "",
                       issuanceDate: issuance, image: nil, hasLocal: false, chainId: nil)
        } catch {
            self.logFailure("resolveSwtcAvatar", host: nftIssuer, error: error)
            return nil
        }
    }

    public func resolveEthrAvatar(vc: String) async -> Nft? {
        guard let root = self.parseVc(vc) else { return nil }
        let tokenId = Json.readString(root, "credentialSubject.tokenId", default: "")
        let contract = Json.readString(root, "credentialSubject.contractAddress", default: "")
        let chainId = Json.readLong(root, "credentialSubject.chainId") // 缺失 = nil（用户要求：不给 chainId 直接失败）
        let issuance = Json.readString(root, "issuanceDate", default: "")
        // 未知 chainId（VC 未给）：链上解析无意义（"0x0" 查库必 miss、getRpcNode(nil) 无节点）——
        // 整个函数直接返回 nil，不产出 uri/image 全空的壳 Nft（用户要求）。
        guard !tokenId.isEmpty, !contract.isEmpty, let chainId else { return nil }

        do {
            // 1) nft_meta 命中（本地 tokenUri 优先；仅当本地缺 tokenUri 时才调 resolver——惰性，省一次 eth_call）
            if let localMeta = try await self.store.nftMeta(contract: contract, tokenId: tokenId) {
                let localTokenUri = self.sanitizeUri(normalizeRemoteAssetURL(localMeta.tokenUri, baseUrl: nil, gateway: self.ipfsGateway))
                let uri = localTokenUri.isEmpty ? await self.resolveEthrTokenUri(contract: contract, tokenId: tokenId, chainId: chainId) : localTokenUri
                return await Nft(
                    contract: contract, tokenId: tokenId, name: localMeta.name ?? "",
                    uri: uri, issuanceDate: issuance,
                    image: self.resolveRemoteImageURL(localMeta.image, uri),
                    hasLocal: true, chainId: chainId
                )
            }
            // 2) evm_nft_items 兜底（resolver 优先级高于本地 metadata，仍须调用）
            let evmItem = try await self.store.evmNftItemByContractAndTokenId(
                chainId: "0x" + String(chainId, radix: 16),
                contractAddress: contract,
                tokenId: tokenId
            )
            let fallbackMetadataUri = self.sanitizeUri(normalizeRemoteAssetURL(evmItem?.metadata, baseUrl: nil, gateway: self.ipfsGateway))
            let resolvedTokenUri = await self.resolveEthrTokenUri(contract: contract, tokenId: tokenId, chainId: chainId)
            let uri = resolvedTokenUri.isEmpty ? fallbackMetadataUri : resolvedTokenUri
            return await Nft(
                contract: contract, tokenId: tokenId, name: evmItem?.title ?? "",
                uri: uri, issuanceDate: issuance,
                image: self.resolveRemoteImageURL(evmItem?.imageUrl, uri),
                hasLocal: !isBlank(evmItem?.imageUrl), chainId: chainId // 修正 Kotlin image != null（空串也算 true）
            )
        } catch {
            self.logFailure("resolveEthrAvatar", host: contract, error: error)
            return nil
        }
    }

    // MARK: - 元数据预取与字段（对齐 NftSdk 3.2）

    public func fetchAndCacheNftMeta(contract: String, tokenId: String, tokenUri: String) async -> NftMeta? {
        let tokenUri = tokenUri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenUri.isEmpty else { return nil }

        // 1) 先归一化（ipfs:// 等 → 最终 HTTP URL），再 SSRF 校验（对齐 Kotlin L-R3 注释）。
        guard let normalized = normalizeRemoteAssetURL(tokenUri, baseUrl: nil, gateway: self.ipfsGateway),
              let url = URL(string: normalized), SsrfGuard.check(url)
        else {
            self.logFailure("fetchAndCacheNftMeta rejected by SsrfGuard", host: self.hostOf(tokenUri))
            return nil
        }
        // 2) 拉取并解析 name/image（失败记日志，不静默吞错——对 Kotlin catch-all 的修正）。
        guard let data = try? await self.httpClient.fetchJson(url) else {
            self.logFailure("fetchAndCacheNftMeta fetch failed", host: self.hostOf(normalized))
            return nil
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            self.logFailure("fetchAndCacheNftMeta parse failed", host: self.hostOf(normalized))
            return nil
        }
        let nameValue = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imageValue = extractMetadataImageURL(dict: json, metadataUri: normalized, gateway: self.ipfsGateway)
        let body = String(data: data, encoding: .utf8) ?? ""

        // 3) upsert（ON CONFLICT DO UPDATE 保留自增 id，对齐 Kotlin copy(id) 语义）→ 读回返回。
        let entity = NftMeta(contract: contract, tokenId: tokenId, name: nameValue,
                             image: imageValue, tokenUri: tokenUri, fullContent: body,
                             updatedAt: Date.nowMillis())
        do {
            try await self.store.upsertNftMeta(entity)
            return try await self.store.nftMeta(contract: contract, tokenId: tokenId)
        } catch {
            self.logFailure("fetchAndCacheNftMeta store failed", host: self.hostOf(normalized), error: error)
            return nil
        }
    }

    public func fetchMetadataFields(_ metadataUri: String) async -> NftMetadataFields {
        guard let normalized = normalizeRemoteAssetURL(metadataUri, baseUrl: nil, gateway: self.ipfsGateway),
              let url = URL(string: normalized)
        else {
            // SSRF 建连门由 NftHttpClient 统一把关（此处不再重复 check，见 review SwiftNft 补充细节）
            self.logFailure("fetchMetadataFields guard failed", host: self.hostOf(metadataUri))
            return .empty
        }
        do {
            guard let body = try await self.httpClient.fetchText(url) else {
                self.logFailure("fetchMetadataFields empty body", host: self.hostOf(metadataUri))
                return .empty
            }
            return extractMetadataFields(body, metadataUri: normalized, gateway: self.ipfsGateway)
        } catch {
            // 与 fetchAndCacheNftMeta 一致：传输错误记日志（review SwiftNft 补充细节）
            self.logFailure("fetchMetadataFields failed", host: self.hostOf(metadataUri), error: error)
            return .empty
        }
    }

    public func ensureSwtcCredentialMetadata(_ vc: String) async {
        guard let root = self.parseVc(vc) else { return }
        let tokenId = Json.readString(root, "credentialSubject.tokenId", default: "")
        let nftIssuer = Json.readString(root, "credentialSubject.nftIssuer", default: "")
        guard !tokenId.isEmpty, !nftIssuer.isEmpty else { return }
        _ = await self.resolveAndCacheSwtcNftMeta(nftIssuer: nftIssuer, tokenId: tokenId)
    }

    // MARK: - 凭证/元数据图片解析（对齐 NftSdk 3.3，4 签名 = 3 方法名 + resolveCredentialImage 重载）

    public func resolveCredentialImage(_ imageUrl: String?, metadataUri: String?) async -> String? {
        await self.resolveRemoteImageURL(imageUrl, metadataUri)
    }

    public func resolveCredentialImage(_ request: CredentialImageRequest) async -> ResolvedCredentialImage? {
        guard let resolvedUrl = await resolveCredentialImage(request.imageUrl, metadataUri: request.metadataUri) else { return nil }
        return ResolvedCredentialImage(url: resolvedUrl, cacheKey: self.buildCredentialAssetKey(request, resolvedUrl: resolvedUrl))
    }

    public func resolveCredentialImages(_ requests: [CredentialImageRequest]) async -> [ResolvedCredentialImage?] {
        guard !requests.isEmpty else { return [] }
        // 按 buildCredentialResolutionKey 去重（对齐 Kotlin LinkedHashMap.getOrPut：nil 值也去重）；
        // **有界并发**（Swift 增强，见 02 §6）：同一 key 只解析一次，不同 key 分批复用
        // ≤ maxConcurrency 个并发——Kotlin 顺序执行、全量并行会让大批量瞬间打满连接/线程。
        let maxConcurrency = 4

        var requestsByKey: [String: CredentialImageRequest] = [:]
        var keysByRequest: [String] = []
        keysByRequest.reserveCapacity(requests.count)
        for request in requests {
            let key = Self.buildCredentialResolutionKey(request, gateway: self.ipfsGateway)
            keysByRequest.append(key)
            if requestsByKey[key] == nil {
                requestsByKey[key] = request
            }
        }

        let uniqueKeys = Array(requestsByKey.keys)
        var resultsByKey: [String: ResolvedCredentialImage?] = [:]
        resultsByKey.reserveCapacity(uniqueKeys.count)
        for start in stride(from: 0, to: uniqueKeys.count, by: maxConcurrency) {
            let end = min(start + maxConcurrency, uniqueKeys.count)
            let batch = uniqueKeys[start ..< end]
            let batchResults = await withTaskGroup(of: (String, ResolvedCredentialImage?).self) { group in
                for key in batch {
                    guard let request = requestsByKey[key] else { continue }
                    group.addTask {
                        let result = await self.resolveCredentialImage(request)
                        return (key, result)
                    }
                }
                var collected: [(String, ResolvedCredentialImage?)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }
            for (key, result) in batchResults {
                resultsByKey[key] = result // 值为 nil 也落字典：同批重复键的失败请求不重拉
            }
        }
        return keysByRequest.map { resultsByKey[$0] ?? nil }
    }

    public func fetchResolvedMetadataImage(_ metadataUrl: String) async -> String? {
        let url = metadataUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let normalized = normalizeRemoteAssetURL(url, baseUrl: nil, gateway: self.ipfsGateway) ?? url
        return await self.imageCache.getOrFetch(normalized) {
            guard let target = URL(string: normalized), SsrfGuard.check(target) else { return nil }
            guard let body = try? await self.httpClient.fetchText(target) else { return nil }
            return extractMetadataImageURLFromBody(body, metadataUri: normalized, gateway: self.ipfsGateway)
        }
    }

    // MARK: - 纯函数（Util/NftUrlUtils.swift，同步；对齐 Kotlin 非 suspend）

    public func normalizeAssetURL(_ rawUrl: String?, baseUrl: String?) -> String? {
        normalizeRemoteAssetURL(rawUrl, baseUrl: baseUrl, gateway: self.ipfsGateway)
    }

    public func extractResolvedMetadataImageURL(_ metadataBody: String, metadataUri: String) -> String? {
        extractMetadataImageURLFromBody(metadataBody, metadataUri: metadataUri, gateway: self.ipfsGateway)
    }

    public func isSupportedRemoteAssetURL(_ url: String?) -> Bool {
        isLoadableRemoteAssetURL(url)
    }

    public func extractSwtcMetadataUri(_ tokenInfosPayload: String?) -> String? {
        parseSwtcMetadataUri(tokenInfosPayload, gateway: self.ipfsGateway)
    }

    // MARK: - 内部：SWTC 元数据预取

    private func resolveAndCacheSwtcNftMeta(nftIssuer: String, tokenId: String) async -> NftMeta? {
        let existing = try? await self.store.nftMeta(contract: nftIssuer, tokenId: tokenId)
        if let existing, !isBlank(existing.image) {
            return existing
        }

        let tokenUri: String? = if let uri = existing?.tokenUri, !isBlank(uri) {
            uri
        } else {
            await self.swtcTokenUriResolver?.fetchMetadataUri(tokenId: tokenId)
        }
        guard let tokenUri else { return existing }
        return await self.fetchAndCacheNftMeta(contract: nftIssuer, tokenId: tokenId, tokenUri: tokenUri) ?? existing
    }

    private func buildSwtcNftFromMeta(nftIssuer: String, tokenId: String, tokenName: String, issuance: String, meta: NftMeta) async -> Nft? {
        let resolvedUri = self.sanitizeUri(normalizeRemoteAssetURL(meta.tokenUri, baseUrl: nil, gateway: self.ipfsGateway))
        let image = await resolveRemoteImageURL(meta.image, resolvedUri)
        if isBlank(image), resolvedUri.isEmpty {
            return nil
        }
        return Nft(
            contract: nftIssuer, tokenId: tokenId, name: meta.name ?? tokenName,
            uri: resolvedUri, issuanceDate: issuance,
            image: image,
            hasLocal: !isBlank(meta.image), // 修正 Kotlin image != null（空串也算 true）
            chainId: nil
        )
    }

    // MARK: - 内部：图片解析（对齐 Kotlin resolveRemoteImageURL 四步）

    /// P1#1：返回给宿主的非 `data:` URL 必须过 SSRF 检查——恶意元数据可注入
    /// `http://192.168.1.1/...`，模块不拦则宿主加载器直接命中内网（宿主侧仍需自行复检）。
    private func isReturnable(_ url: String) -> Bool {
        if url.lowercased().hasPrefix("data:") {
            return true
        }
        guard let parsed = URL(string: url) else { return false }
        return SsrfGuard.check(parsed)
    }

    private func resolveRemoteImageURL(_ imageUrl: String?, _ metadataUri: String?) async -> String? {
        let normalizedMetadataUri = normalizeRemoteAssetURL(metadataUri, baseUrl: nil, gateway: self.ipfsGateway)

        // 1) imageUrl 内联 JSON → 提图
        if let imageUrl {
            let trimmed = imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeJsonPayload(trimmed),
               let inline = extractResolvedMetadataImageURL(trimmed, metadataUri: normalizedMetadataUri ?? "") {
                return inline
            }
        }
        // 2) imageUrl 规范化后可加载 → 直出（data: 仅放行 data:image/*，其余不直出、继续后续步骤）
        if let resolved = normalizeRemoteAssetURL(imageUrl, baseUrl: normalizedMetadataUri, gateway: self.ipfsGateway),
           isLoadableRemoteAssetURL(resolved) {
            if resolved.lowercased().hasPrefix("data:") {
                if isDataImageURL(resolved) {
                    return resolved
                }
            } else if self.isReturnable(resolved) {
                return resolved // P1#1：私网/回环等不可返回
            }
        }
        // 3) metadataUri 本身是图片 URL → 直出（data: 同上，仅放行 data:image/*）
        if let normalizedMetadataUri, !isBlank(normalizedMetadataUri), looksLikeImageAssetURL(normalizedMetadataUri) {
            if normalizedMetadataUri.lowercased().hasPrefix("data:") {
                if isDataImageURL(normalizedMetadataUri) {
                    return normalizedMetadataUri
                }
            } else if self.isReturnable(normalizedMetadataUri) {
                return normalizedMetadataUri
            }
        }
        // 4) 拉元数据提图（记忆化缓存；data: 元数据不可拉取——SSRF 拒 data:，且步骤 3 已处理
        //    data:image/* 直出——提前短路，避免无效缓存键与（旁路测试下的）无谓拉取）
        guard let normalizedMetadataUri, !normalizedMetadataUri.lowercased().hasPrefix("data:") else { return nil }
        let metadataImage = await imageCache.getOrFetch(normalizedMetadataUri) {
            // SSRF 建连门由 NftHttpClient 统一把关（此处不再重复 check——client 门更贴近建连，
            // 单点解析省一次 DNS 且缩小 TOCTOU，见 review SwiftNft 补充细节）
            guard let url = URL(string: normalizedMetadataUri) else { return nil }
            guard let body = try? await self.httpClient.fetchText(url) else { return nil }
            return extractMetadataImageURLFromBody(body, metadataUri: normalizedMetadataUri, gateway: self.ipfsGateway)
        }
        guard let metadataImage else { return nil }
        if metadataImage.lowercased().hasPrefix("data:") {
            // 直出仅放行 data:image/*（与 step 2/3 同口径）；否则 data:text/html 会经 isLoadableRemoteAssetURL 漏出
            return isDataImageURL(metadataImage) ? metadataImage : nil
        }
        if let resolved = normalizeRemoteAssetURL(metadataImage, baseUrl: normalizedMetadataUri, gateway: self.ipfsGateway),
           isLoadableRemoteAssetURL(resolved), self.isReturnable(resolved) {
            return resolved // P1#1：非 data: 返回必须过 SSRF
        }
        return nil
    }

    // MARK: - 内部：缓存键（对齐 Kotlin buildCredentialAssetKey / buildCredentialResolutionKey）

    private func buildCredentialAssetKey(_ request: CredentialImageRequest, resolvedUrl: String) -> String {
        let trimmed = resolvedUrl.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return "image:\(trimmed)"
        }
        let contract = request.contractAddress?.trimmingCharacters(in: .whitespaces)
        let tokenId = request.tokenId?.trimmingCharacters(in: .whitespaces)
        if let contract, !contract.isEmpty, let tokenId, !tokenId.isEmpty {
            let chain = request.chainId.map(String.init) ?? "unknown"
            return "nft:\(chain):\(contract.lowercased()):\(tokenId)"
        }
        let metadataUri = request.metadataUri?.trimmingCharacters(in: .whitespaces)
        if let metadataUri, !metadataUri.isEmpty {
            let normalized = normalizeRemoteAssetURL(metadataUri, baseUrl: nil, gateway: self.ipfsGateway)?
                .trimmingCharacters(in: .whitespaces)
            return "metadata:\(normalized?.nilIfBlank ?? metadataUri)"
        }
        let imageUrl = request.imageUrl?.trimmingCharacters(in: .whitespaces)
        if let imageUrl, !imageUrl.isEmpty {
            let normalized = normalizeRemoteAssetURL(imageUrl, baseUrl: request.metadataUri, gateway: self.ipfsGateway)?
                .trimmingCharacters(in: .whitespaces)
            return "image:\(normalized?.nilIfBlank ?? imageUrl)"
        }
        // 全字段为空 → 恒定键 "image:"（所有空请求共享同一缓存键；review SwiftNft 补充细节）
        return "image:"
    }

    private static func buildCredentialResolutionKey(_ request: CredentialImageRequest, gateway: String) -> String {
        [
            request.chainId.map(String.init) ?? "",
            request.contractAddress?.trimmingCharacters(in: .whitespaces).lowercased() ?? "",
            request.tokenId?.trimmingCharacters(in: .whitespaces) ?? "",
            normalizeRemoteAssetURL(request.metadataUri, baseUrl: nil, gateway: gateway)?.trimmingCharacters(in: .whitespaces) ?? "",
            normalizeRemoteAssetURL(request.imageUrl, baseUrl: request.metadataUri, gateway: gateway)?.trimmingCharacters(in: .whitespaces) ?? ""
        ].joined(separator: "|")
    }

    // MARK: - 内部：VC JSON 解析（调用点先 parse 一次，再用 `SwiftCore.Json` 取路径，

    // 见跨模块重复 2.1 / 性能专项 D-3——避免逐字段重复解析）

    private func parseVc(_ vc: String) -> [String: Any]? {
        guard let data = vc.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func sanitizeUri(_ uri: String?) -> String {
        guard let uri else { return "" }
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeJsonPayload(trimmed) else { return "" }
        return trimmed
    }

    /// 惰性解析 EVM tokenURI（本地数据足够时不发起 eth_call；结果经 resolver 记忆化缓存）。
    /// 二次 `normalizeRemoteAssetURL`（D-2）：resolver 已按注入 gateway 归一，这里再按门面配置
    /// gateway 兜底归一一次（http `/ipfs/` 路径强制换到配置网关；ipfs:// 若 resolver 漏过则补上）。
    private func resolveEthrTokenUri(contract: String, tokenId: String, chainId: Int64) async -> String {
        let uri = await self.ethTokenUriResolver?.resolveEthrTokenUri(contract: contract, tokenId: tokenId, chainId: chainId)
        return self.sanitizeUri(normalizeRemoteAssetURL(uri, baseUrl: nil, gateway: self.ipfsGateway))
    }

    private func hostOf(_ url: String) -> String {
        URL(string: url)?.host ?? "unknown"
    }

    private func logFailure(_ message: String, host: String, error: Error? = nil) {
        // 只打 scheme/host 与错误码，不打 body / localizedDescription——
        // GRDB/URLError 的 localizedDescription 可能含 SQL/绑定值/URL 等 payload（对齐「日志不打 payload」）。
        if let nsError = error as NSError? {
            self.logger.error("\(message, privacy: .public) host=\(host, privacy: .public) errDomain=\(nsError.domain, privacy: .public) errCode=\(nsError.code, privacy: .public)")
        } else {
            self.logger.error("\(message, privacy: .public) host=\(host, privacy: .public)")
        }
    }
}
