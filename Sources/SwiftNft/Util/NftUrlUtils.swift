import Foundation

// MARK: - 资产 URL 规范化（对齐 Kotlin :nft remote/NftRemoteAssetResolver.kt 纯函数，commit f77b59f）

//
// 网关为**参数**（默认 IpfsResolver.defaultGateway），门面把 config.ipfsGateway 层层传入——
// 否则「可注入网关」只对 rewrite 一条路径生效、ipfs:// 重写仍硬编码默认网关（见 Nft-Swift 02 §4 / 04 坑 #9）。

/// IPFS 网关（默认对齐 Kotlin `DEFAULT_IPFS_GATEWAY_BASE_URL`，可注入）。
public enum IpfsResolver {
    public static let defaultGateway = "https://ipfs.jccdex.cn/ipfs/"

    /// ipfs://<CID> → https://<gateway>/<CID>（含冗余前缀剥除）。
    public static func rewrite(_ raw: String, gateway: String = defaultGateway) -> String? {
        normalizeRemoteAssetUrl(raw, baseUrl: nil, gateway: gateway)
    }
}

// MARK: - 判定

/// 可加载的远程资产 URL：http/https/**data:** 前缀即 true（对齐 Kotlin `isLoadableRemoteAssetUrl`）。
public func isLoadableRemoteAssetUrl(_ url: String?) -> Bool {
    guard let value = url?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
    let lower = value.lowercased()
    return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:")
}

/// 独立的 data: 图片检查（Swift 设计决策）：解析路径直出前仅放行 `data:image/*`。
/// 注意：`image/svg+xml` 命中但其中可含脚本——渲染须走 UIImage/CGImage，勿用 WKWebView（见 Nft-Swift 02 §8）。
public func isDataImageUrl(_ url: String?) -> Bool {
    guard let value = url?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
    return value.lowercased().hasPrefix("data:image/")
}

/// 形如图片资产 URL：`data:` 或路径后缀 ∈ {.png,.jpg,.jpeg,.webp,.gif,.svg,.avif,.bmp}（对齐 Kotlin）。
func looksLikeImageAssetUrl(_ value: String) -> Bool {
    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isLoadableRemoteAssetUrl(v) else { return false }
    if v.lowercased().hasPrefix("data:") {
        return true
    }
    let path = URL(string: v)?.path.lowercased() ?? ""
    return [".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".avif", ".bmp"].contains { path.hasSuffix($0) }
}

/// 以 `{`/`[` 开头的 payload 视为内联 JSON（对齐 Kotlin `looksLikeJsonPayload`）。
func looksLikeJsonPayload(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
}

/// 裸 IPFS 标识：CID 以 `bafy`（忽略大小写）或 `Qm` 开头（对齐 Kotlin `looksLikeIpfsIdentifier`）。
func looksLikeIpfsIdentifier(_ value: String) -> Bool {
    let trimmed = value.trimmingPrefix("/")
    return trimmed.lowercased().hasPrefix("bafy") || trimmed.hasPrefix("Qm")
}

// MARK: - normalizeRemoteAssetUrl

/// 资产 URL 规范化（对齐 Kotlin `normalizeRemoteAssetUrl`，含自定义网关参数）：
/// 1. nil/空白/JSON-looking → nil；
/// 2. `ipfs://` / `/ipfs/` / `ipfs/` 前缀与裸 CID → 网关 URL；
/// 3. http(s) 路径含 `/ipfs/` → 强制换网关（canonicalizeHttpIpfsUrl）；其余 http(s)/data: 原样；
/// 4. 相对路径 → `URL(base, raw)` 标准解析（无 base 时原样返回——对齐 Kotlin，不判 nil）。
public func normalizeRemoteAssetUrl(
    _ rawUrl: String?,
    baseUrl: String? = nil,
    gateway: String = IpfsResolver.defaultGateway
) -> String? {
    guard let rawUrl else { return nil }
    let value = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !looksLikeJsonPayload(value) else { return nil }

    let lower = value.lowercased()
    if lower.hasPrefix("ipfs://") {
        let path = value.dropFirst("ipfs://".count).removingPrefix("ipfs/").trimmingPrefix("/")
        return path.isEmpty ? nil : gateway + path
    }
    if lower.hasPrefix("/ipfs/") {
        let path = value.dropFirst("/ipfs/".count).trimmingPrefix("/")
        return path.isEmpty ? nil : gateway + path
    }
    if lower.hasPrefix("ipfs/") {
        let path = value.dropFirst("ipfs/".count).trimmingPrefix("/")
        return path.isEmpty ? nil : gateway + path
    }
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") {
        return canonicalizeHttpIpfsUrl(value, gateway: gateway) ?? value
    }
    if looksLikeIpfsIdentifier(value) {
        return gateway + value.trimmingPrefix("/")
    }
    return resolveRelativeAssetUrl(baseUrl, value)
}

/// http(s) 路径中含 `/ipfs/` 的 URL 强制换到（可配置的）网关（对齐 Kotlin `canonicalizeHttpIpfsUrl`）。
/// 注意：网关可注入后可能误伤第三方 URL（如 `https://cdn.thirdparty.com/ipfs/xyz`）——
/// 「保持 Kotlin 行为」或「限定已知 IPFS 网关域名」二选一固化（见 Nft-Swift 03 §4.2 / 04 坑 #9）。
func canonicalizeHttpIpfsUrl(_ rawUrl: String, gateway: String = IpfsResolver.defaultGateway) -> String? {
    let lower = rawUrl.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
    guard let parsed = URL(string: rawUrl) else { return nil }
    let marker = "/ipfs/"
    guard let range = parsed.path.range(of: marker, options: .caseInsensitive) else { return nil }
    let ipfsPath = String(parsed.path[range.upperBound...]).trimmingPrefix("/")
    guard !ipfsPath.isEmpty else { return nil }
    return gateway + ipfsPath
}

func resolveRelativeAssetUrl(_ baseUrl: String?, _ rawValue: String) -> String {
    guard let baseUrl, let base = URL(string: baseUrl) else { return rawValue }
    return URL(string: rawValue, relativeTo: base)?.absoluteString ?? rawValue
}

// MARK: - 元数据提取

/// 从元数据 JSON body 提取图片 URL（便捷版，用默认网关；落地用注入网关请走 `extractMetadataImageUrlFromBody`）。
public func extractResolvedMetadataImageUrl(_ metadataBody: String, metadataUri: String) -> String? {
    extractMetadataImageUrlFromBody(metadataBody, metadataUri: metadataUri)
}

/// 从元数据 JSON body 提取图片 URL（对齐 Kotlin `extractMetadataImageUrl`，带 gateway 参数）：
/// `data` 键解包 → 键顺序 `image`/`image_url`/`imageUrl` → 首个非空且可规范化。
func extractMetadataImageUrlFromBody(
    _ metadataBody: String,
    metadataUri: String,
    gateway: String = IpfsResolver.defaultGateway
) -> String? {
    guard let data = metadataBody.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return extractMetadataImageUrl(dict: root, metadataUri: metadataUri, gateway: gateway)
}

/// dict 版（fetchJson 的 Data → JSON 解析后使用，避免二次序列化）。
func extractMetadataImageUrl(
    dict: [String: Any],
    metadataUri: String,
    gateway: String = IpfsResolver.defaultGateway
) -> String? {
    let payload = (dict["data"] as? [String: Any]) ?? dict
    for key in ["image", "image_url", "imageUrl"] {
        let value = optString(payload, key)
        if !value.isEmpty, let normalized = normalizeRemoteAssetUrl(value, baseUrl: metadataUri, gateway: gateway) {
            return normalized
        }
    }
    return nil
}

/// 元数据字段提取（对齐 Kotlin `extractMetadataFields`）：失败返回 `.empty`（非 Optional 语义）。
public func extractMetadataFields(
    _ metadataBody: String,
    metadataUri: String,
    gateway: String = IpfsResolver.defaultGateway
) -> NftMetadataFields {
    guard let data = metadataBody.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return .empty }
    let payload = (root["data"] as? [String: Any]) ?? root
    let image = extractMetadataImageUrl(dict: root, metadataUri: metadataUri, gateway: gateway)
    let name = optString(payload, "name").nilIfBlank
    let description = optString(payload, "description").nilIfBlank
    return NftMetadataFields(image: image, name: name, description: description)
}

/// 对齐 org.json `JSONObject.optString`：缺失返回 ""，数字/布尔按需转换。
func optString(_ dict: [String: Any], _ key: String) -> String {
    if let value = dict[key] {
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
    }
    return ""
}

// MARK: - SWTC 元数据 URI（erc_info TokenInfos 解析）

/// 从 `erc_info` 的 `TokenInfos` payload 提取元数据 URI（对齐 Kotlin `extractSwtcMetadataUri`；
/// Kotlin 在 NftStore 里 import 别名 `parseSwtcMetadataUri`，Swift 直接用该名避免与门面方法重名）：
/// 遍历数组，hex 解码 `InfoType == "tokenUri"` 项，hex 解码 `InfoData` 并规范化。
func parseSwtcMetadataUri(_ tokenInfosPayload: String?) -> String? {
    guard let payload = tokenInfosPayload, !payload.isEmpty,
          let data = payload.data(using: .utf8),
          let infos = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    else { return nil }
    for element in infos {
        guard let item = element as? [String: Any],
              let tokenInfo = item["TokenInfo"] as? [String: Any]
        else { continue }
        let infoType = decodeHexToUtf8(optString(tokenInfo, "InfoType"))
        guard infoType == "tokenUri" else { continue }
        let infoData = decodeHexToUtf8(optString(tokenInfo, "InfoData"))
        if let normalized = normalizeRemoteAssetUrl(infoData, baseUrl: nil) {
            return normalized
        }
    }
    return nil
}

/// hex 字符串 → UTF-8 文本（剥 `0x` 前缀、去空白；非偶数/非法字节 → ""，对齐 Kotlin `decodeHexToUtf8`）。
func decodeHexToUtf8(_ hex: String) -> String {
    var clean = hex
    if clean.lowercased().hasPrefix("0x") {
        clean = String(clean.dropFirst(2))
    }
    clean = clean.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
    guard !clean.isEmpty, clean.count % 2 == 0 else { return "" }
    var bytes = [UInt8]()
    bytes.reserveCapacity(clean.count / 2)
    var index = clean.startIndex
    while index < clean.endIndex {
        let next = clean.index(index, offsetBy: 2)
        guard let byte = UInt8(clean[index ..< next], radix: 16) else { return "" }
        bytes.append(byte)
        index = next
    }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}

// MARK: - 内部小工具

extension StringProtocol {
    func trimmingPrefix(_ prefix: Character) -> String {
        String(drop(while: { $0 == prefix }))
    }

    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : String(self)
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// 空白判定（对齐 Kotlin `isNullOrBlank`）。
func isBlank(_ value: String?) -> Bool {
    guard let value else { return true }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
