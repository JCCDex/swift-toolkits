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
    func normalizeAssetUrl(_ rawUrl: String?, baseUrl: String?) -> String?
    func extractResolvedMetadataImageUrl(_ metadataBody: String, metadataUri: String) -> String?
    func isSupportedRemoteAssetUrl(_ url: String?) -> Bool
    func extractSwtcMetadataUri(_ tokenInfosPayload: String?) -> String?
    func fetchMetadataFields(_ metadataUri: String) async -> NftMetadataFields
    func ensureSwtcCredentialMetadata(_ vc: String) async
}

// MARK: - SwiftNft 门面（镜像 Kotlin NftSdk 14 方法）

/// 门面：自由线程（非 @MainActor，对齐 `DidNftResolution` 协议缝）。
/// 解析/编排逻辑在此（Kotlin 在 NftStore 内实现；Swift 让 NftStore 保持纯存储，见 02 §5）。
public final class SwiftNft: DidNftResolution, Sendable {
    // 配置拆为成员变量（不持有 SwiftNftConfig 单一对象）：
    private let store: any NftStore
    private let ipfsGateway: String // 贯穿所有 ipfs→网关重写（normalizedGateway 已保证尾部 `/`）
    private let httpClient: any NftHttpClient
    private let ethTokenUriResolver: (any IEthTokenUriResolver)? // EVM tokenURI（模块默认 EthTokenUriResolver）
    private let swtcTokenUriResolver: (any ISwtcTokenUriResolver)? // 宿主注入；nil = SWTC 元数据解析不可用

    private let imageCache = NftMetadataImageCache()
    private let logger = Logger(subsystem: "com.jccdex.toolkits.swiftnft", category: "SwiftNft")

    public init(config: SwiftNftConfig) {
        // 网关校验：注入的 ipfsGateway 必须 http/https（normalizedGateway 已保证尾部 `/`）。
        // 非法值回退默认网关，而非 precondition crash 宿主（配置错误不应崩 App）。
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
        if self.ipfsGateway != resolved.ipfsGateway {
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
            if let localMeta = try await self.store.getNftMeta(contract: nftIssuer, tokenId: tokenId),
               let nft = await buildSwtcNftFromMeta(nftIssuer: nftIssuer, tokenId: tokenId,
                                                    tokenName: tokenName, issuance: issuance, meta: localMeta) {
                return nft
            }
            // 2) swtc_nfts 行命中（image 或 metadataUri 非空）
            if let swtcNft = try await self.store.getSwtcNftByIssuerAndTokenId(issuer: nftIssuer, tokenId: tokenId) {
                let resolvedUri = self.sanitizeUri(normalizeRemoteAssetUrl(swtcNft.metadataUri, baseUrl: nil, gateway: self.ipfsGateway))
                if !isBlank(swtcNft.image) || !resolvedUri.isEmpty {
                    return await Nft(
                        contract: nftIssuer,
                        tokenId: tokenId,
                        name: swtcNft.name ?? tokenName,
                        uri: resolvedUri,
                        issuanceDate: issuance,
                        image: self.resolveRemoteImageUrl(swtcNft.image, resolvedUri),
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
        let chainId = Json.readLong(root, "credentialSubject.chainId", default: 0)
        let issuance = Json.readString(root, "issuanceDate", default: "")
        guard !tokenId.isEmpty, !contract.isEmpty else { return nil }

        do {
            // 1) nft_meta 命中（本地 tokenUri 优先；仅当本地缺 tokenUri 时才调 resolver——惰性，省一次 eth_call）
            if let localMeta = try await self.store.getNftMeta(contract: contract, tokenId: tokenId) {
                let localTokenUri = self.sanitizeUri(normalizeRemoteAssetUrl(localMeta.tokenUri, baseUrl: nil, gateway: self.ipfsGateway))
                let uri = localTokenUri.isEmpty ? await self.resolveEthrTokenUri(contract: contract, tokenId: tokenId, chainId: chainId) : localTokenUri
                return await Nft(
                    contract: contract, tokenId: tokenId, name: localMeta.name ?? "",
                    uri: uri, issuanceDate: issuance,
                    image: self.resolveRemoteImageUrl(localMeta.image, uri),
                    hasLocal: true, chainId: chainId
                )
            }
            // 2) evm_nft_items 兜底（resolver 优先级高于本地 metadata，仍须调用）
            let evmItem = try await self.store.getEvmNftItemByContractAndTokenId(
                chainId: "0x" + String(chainId, radix: 16),
                contractAddress: contract,
                tokenId: tokenId
            )
            let fallbackMetadataUri = self.sanitizeUri(normalizeRemoteAssetUrl(evmItem?.metadata, baseUrl: nil, gateway: self.ipfsGateway))
            let resolvedTokenUri = await self.resolveEthrTokenUri(contract: contract, tokenId: tokenId, chainId: chainId)
            let uri = resolvedTokenUri.isEmpty ? fallbackMetadataUri : resolvedTokenUri
            return await Nft(
                contract: contract, tokenId: tokenId, name: evmItem?.title ?? "",
                uri: uri, issuanceDate: issuance,
                image: self.resolveRemoteImageUrl(evmItem?.imageUrl, uri),
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
        guard let normalized = normalizeRemoteAssetUrl(tokenUri, baseUrl: nil, gateway: self.ipfsGateway),
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
        let imageValue = extractMetadataImageUrl(dict: json, metadataUri: normalized, gateway: self.ipfsGateway)
        let body = String(data: data, encoding: .utf8) ?? ""

        // 3) upsert（ON CONFLICT DO UPDATE 保留自增 id，对齐 Kotlin copy(id) 语义）→ 读回返回。
        let entity = NftMeta(contract: contract, tokenId: tokenId, name: nameValue,
                             image: imageValue, tokenUri: tokenUri, fullContent: body,
                             updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        do {
            try await self.store.upsertNftMeta(entity)
            return try await self.store.getNftMeta(contract: contract, tokenId: tokenId)
        } catch {
            self.logFailure("fetchAndCacheNftMeta store failed", host: self.hostOf(normalized), error: error)
            return nil
        }
    }

    public func fetchMetadataFields(_ metadataUri: String) async -> NftMetadataFields {
        guard let normalized = normalizeRemoteAssetUrl(metadataUri, baseUrl: nil, gateway: self.ipfsGateway),
              let url = URL(string: normalized), SsrfGuard.check(url)
        else { return .empty }
        guard let body = try? await self.httpClient.fetchText(url) else { return .empty }
        return extractMetadataFields(body, metadataUri: normalized, gateway: self.ipfsGateway)
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
        await self.resolveRemoteImageUrl(imageUrl, metadataUri)
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
        let normalized = normalizeRemoteAssetUrl(url, baseUrl: nil, gateway: self.ipfsGateway) ?? url
        return await self.imageCache.getOrFetch(normalized) {
            guard let target = URL(string: normalized), SsrfGuard.check(target) else { return nil }
            guard let body = try? await self.httpClient.fetchText(target) else { return nil }
            return extractMetadataImageUrlFromBody(body, metadataUri: normalized, gateway: self.ipfsGateway)
        }
    }

    // MARK: - 纯函数（Util/NftUrlUtils.swift，同步；对齐 Kotlin 非 suspend）

    public func normalizeAssetUrl(_ rawUrl: String?, baseUrl: String?) -> String? {
        normalizeRemoteAssetUrl(rawUrl, baseUrl: baseUrl, gateway: self.ipfsGateway)
    }

    public func extractResolvedMetadataImageUrl(_ metadataBody: String, metadataUri: String) -> String? {
        extractMetadataImageUrlFromBody(metadataBody, metadataUri: metadataUri, gateway: self.ipfsGateway)
    }

    public func isSupportedRemoteAssetUrl(_ url: String?) -> Bool {
        isLoadableRemoteAssetUrl(url)
    }

    public func extractSwtcMetadataUri(_ tokenInfosPayload: String?) -> String? {
        parseSwtcMetadataUri(tokenInfosPayload, gateway: self.ipfsGateway)
    }

    // MARK: - 内部：SWTC 元数据预取

    private func resolveAndCacheSwtcNftMeta(nftIssuer: String, tokenId: String) async -> NftMeta? {
        let existing = try? await self.store.getNftMeta(contract: nftIssuer, tokenId: tokenId)
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
        let resolvedUri = self.sanitizeUri(normalizeRemoteAssetUrl(meta.tokenUri, baseUrl: nil, gateway: self.ipfsGateway))
        let image = await resolveRemoteImageUrl(meta.image, resolvedUri)
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

    // MARK: - 内部：图片解析（对齐 Kotlin resolveRemoteImageUrl 四步）

    private func resolveRemoteImageUrl(_ imageUrl: String?, _ metadataUri: String?) async -> String? {
        let normalizedMetadataUri = normalizeRemoteAssetUrl(metadataUri, baseUrl: nil, gateway: self.ipfsGateway)

        // 1) imageUrl 内联 JSON → 提图
        if let imageUrl {
            let trimmed = imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeJsonPayload(trimmed),
               let inline = extractResolvedMetadataImageUrl(trimmed, metadataUri: normalizedMetadataUri ?? "") {
                return inline
            }
        }
        // 2) imageUrl 规范化后可加载 → 直出（data: 仅放行 data:image/*，其余不直出、继续后续步骤）
        if let resolved = normalizeRemoteAssetUrl(imageUrl, baseUrl: normalizedMetadataUri, gateway: self.ipfsGateway),
           isLoadableRemoteAssetUrl(resolved) {
            if resolved.lowercased().hasPrefix("data:") {
                if isDataImageUrl(resolved) {
                    return resolved
                }
            } else {
                return resolved
            }
        }
        // 3) metadataUri 本身是图片 URL → 直出（data: 同上，仅放行 data:image/*）
        if let normalizedMetadataUri, !isBlank(normalizedMetadataUri), looksLikeImageAssetUrl(normalizedMetadataUri) {
            if normalizedMetadataUri.lowercased().hasPrefix("data:") {
                if isDataImageUrl(normalizedMetadataUri) {
                    return normalizedMetadataUri
                }
            } else {
                return normalizedMetadataUri
            }
        }
        // 4) 拉元数据提图（记忆化缓存；data: 元数据不可拉取——SSRF 拒 data:，且步骤 3 已处理
        //    data:image/* 直出——提前短路，避免无效缓存键与（旁路测试下的）无谓拉取）
        guard let normalizedMetadataUri, !normalizedMetadataUri.lowercased().hasPrefix("data:") else { return nil }
        let metadataImage = await imageCache.getOrFetch(normalizedMetadataUri) {
            guard let url = URL(string: normalizedMetadataUri), SsrfGuard.check(url) else { return nil }
            guard let body = try? await self.httpClient.fetchText(url) else { return nil }
            return extractMetadataImageUrlFromBody(body, metadataUri: normalizedMetadataUri, gateway: self.ipfsGateway)
        }
        guard let metadataImage else { return nil }
        if metadataImage.lowercased().hasPrefix("data:") {
            // 直出仅放行 data:image/*（与 step 2/3 同口径）；否则 data:text/html 会经 isLoadableRemoteAssetUrl 漏出
            return isDataImageUrl(metadataImage) ? metadataImage : nil
        }
        if let resolved = normalizeRemoteAssetUrl(metadataImage, baseUrl: normalizedMetadataUri, gateway: self.ipfsGateway),
           isLoadableRemoteAssetUrl(resolved) {
            return resolved
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
            let normalized = normalizeRemoteAssetUrl(metadataUri, baseUrl: nil, gateway: self.ipfsGateway)?
                .trimmingCharacters(in: .whitespaces)
            return "metadata:\(normalized?.isEmpty == false ? normalized! : metadataUri)"
        }
        let imageUrl = request.imageUrl?.trimmingCharacters(in: .whitespaces)
        if let imageUrl, !imageUrl.isEmpty {
            let normalized = normalizeRemoteAssetUrl(imageUrl, baseUrl: request.metadataUri, gateway: self.ipfsGateway)?
                .trimmingCharacters(in: .whitespaces)
            return "image:\(normalized?.isEmpty == false ? normalized! : imageUrl)"
        }
        return "image:\(trimmed)"
    }

    private static func buildCredentialResolutionKey(_ request: CredentialImageRequest, gateway: String) -> String {
        [
            request.chainId.map(String.init) ?? "",
            request.contractAddress?.trimmingCharacters(in: .whitespaces).lowercased() ?? "",
            request.tokenId?.trimmingCharacters(in: .whitespaces) ?? "",
            normalizeRemoteAssetUrl(request.metadataUri, baseUrl: nil, gateway: gateway)?.trimmingCharacters(in: .whitespaces) ?? "",
            normalizeRemoteAssetUrl(request.imageUrl, baseUrl: request.metadataUri, gateway: gateway)?.trimmingCharacters(in: .whitespaces) ?? ""
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

    /// 惰性解析 EVM tokenURI（本地数据足够时不发起 eth_call）。
    private func resolveEthrTokenUri(contract: String, tokenId: String, chainId: Int64) async -> String {
        let uri = await self.ethTokenUriResolver?.resolveEthrTokenUri(contract: contract, tokenId: tokenId, chainId: chainId)
        return self.sanitizeUri(normalizeRemoteAssetUrl(uri, baseUrl: nil, gateway: self.ipfsGateway))
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
