import Foundation
import SwiftCore

/// 根据 chainId 返回该链的 RPC URL（nil = 无可用节点 → 解析返回 nil）。
/// 对齐 Kotlin `defaultRpcUrlsForChain(chainId)`（app 侧内置）——Swift 由宿主经 init 注入，模块不内置端点。
public typealias ChainRpcUrlsProvider = @Sendable (Int64) -> String?

/// EVM `tokenURI(uint256)` 解析器（eth_call）——`IEthTokenUriResolver` 的默认实现。
///
/// 移植自 Kotlin app 侧 `com.android.jdid.repository.DefaultEthTokenUriResolver`，
/// 按用户要求收纳进 `:nft` 模块：
/// - `buildTokenUriCallData`：仅拼 selector `0xc87b56dd` + **32 字节 tokenId**（合约地址走 `to`
///   字段，不进 calldata）；tokenId 按**十进制**解析转 hex（逐位除法，支持任意长度 uint256）；
/// - `decodeAbiString`：ABI string 解码（假定 offset=32，取第 2 个 32 字节字为长度，数据从第 128 hex 位起）；
/// - `normalizeTokenMetadataUri`：`normalizeRemoteAssetURL(raw, gateway:) ?: raw`（ipfs:// → 网关；
///   `gateway` 由 init 注入、贯穿内部归一——门面不再二次归一，见 review D-2）；
/// - **RPC URL 由 `init(getRpcNode:)` 注入**（chainId → RPC URL 的函数），本类不内置任何端点——
///   端点属宿主配置（对应 Kotlin `AppEndpoints.RPC_*`）；
/// - **网络走模块 `NftHttpClient`**（`fetchRpc`：POST JSON-RPC、跟随重定向；RPC 节点属宿主注入
///   信任面，不做 SsrfGuard 建连检查——SsrfGuard/上限由客户端统一（GET 元数据拉取））；
/// - **eth_call 结果记忆化**：复用 `AsyncMemoCache`（按 key 缓存成功结果 + per-key
///   in-flight 去重 + LRU 上限 + generation 防旧回写，见 review D-1）。
public final class EthTokenUriResolver: IEthTokenUriResolver {
    private let getRpcNode: ChainRpcUrlsProvider
    private let httpClient: any NftHttpClient
    private let gateway: String // ipfs→网关重写用（init 注入；normalizedGateway 保证尾部 `/`）
    private let tokenUriCache = AsyncMemoCache(maxEntries: 128)

    /// - Parameters:
    ///   - getRpcNode: 根据 chainId 返回该链 RPC URL 的函数（宿主注入；nil = 无节点）。
    ///   - httpClient: 网络客户端（默认 `URLSessionNftHttpClient`；测试可注入 URLProtocol 桩 session）。
    ///   - gateway: ipfs→网关重写（默认 `IpfsResolver.defaultGateway`；门面按配置注入即单次归一，见 review D-2）。
    public init(
        getRpcNode: @escaping ChainRpcUrlsProvider,
        httpClient: any NftHttpClient = URLSessionNftHttpClient(),
        gateway: String = IpfsResolver.defaultGateway
    ) {
        self.getRpcNode = getRpcNode
        self.httpClient = httpClient
        self.gateway = IpfsResolver.normalizedGateway(gateway)
    }

    public func resolveEthrTokenUri(contract: String, tokenId: String, chainId: Int64) async -> String? {
        guard let callData = Self.buildTokenUriCallData(tokenId: tokenId) else { return nil }
        guard let rpcUrl = self.getRpcNode(chainId) else { return nil }
        // D-1：同 (chainId, contract, tokenId) 并发只发一次 eth_call；成功结果缓存（失败不缓存，可重试）。
        // key 无空白，`AsyncMemoCache` 的 trim 为 no-op。
        let key = "\(chainId)|\(contract)|\(tokenId)"
        return await self.tokenUriCache.getOrFetch(key) {
            await self.fetchTokenUri(rpcUrl: rpcUrl, contract: contract, callData: callData)
        }
    }

    // MARK: - eth_call

    private func fetchTokenUri(rpcUrl: String, contract: String, callData: String) async -> String? {
        guard let url = URL(string: rpcUrl) else { return nil }
        // 对齐 Kotlin：RPC 节点可信，跟随重定向（fetchRpc 语义）
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "eth_call",
            "params": [["to": contract, "data": callData], "latest"],
            "id": 1
        ]) else { return nil }

        guard let data = try? await self.httpClient.fetchRpc(url, body: body),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawResult = json["result"] as? String
        else { return nil }
        return Self.normalizeTokenMetadataUri(Self.decodeAbiString(rawResult), gateway: self.gateway)
    }

    // MARK: - calldata / 解码（对齐 Kotlin 顶层函数）

    /// `"0xc87b56dd" + tokenId(32B)`；tokenId 十进制字符串 → 任意长度 hex，失败返回 nil。
    static func buildTokenUriCallData(tokenId: String) -> String? {
        guard let bytes = decimalStringToBytes(tokenId), bytes.count <= 32 else { return nil }
        let hex = Hex.encode(bytes)
        return "0xc87b56dd" + String(repeating: "0", count: 64 - hex.count) + hex
    }

    /// ABI 编码字符串解码（假定 offset = 32）：`0x` + offset(64 hex) + length(64 hex) + utf8(+ padding)。
    static func decodeAbiString(_ hex: String?) -> String? {
        var normalized = hex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty || normalized == "0x" {
            return nil
        }
        if normalized.hasPrefix("0x") {
            normalized = String(normalized.dropFirst(2))
        }
        guard normalized.count >= 128 else { return nil } // offset + length 至少 128 hex 位

        guard let length = Int(normalized[64 ..< 128], radix: 16),
              length >= 0,
              // P0-4：length 来自链上不可信数据（64 hex 位，可解析到 2^62..<2^63）；
              // 必须在乘法前按剩余数据量界住——否则 length * 2 溢出 Int64 → 运行时
              // 崩溃（恶意合约的 tokenURI 返回值即可远程触发）。
              length <= (normalized.count - 128) / 2
        else { return nil }
        let dataEnd = 128 + length * 2

        let dataHex = String(normalized[128 ..< dataEnd])
        guard let bytes = Hex.decode(dataHex) else { return nil }
        let value = String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// ipfs:// 等 → 网关；其余原样（对齐 Kotlin `normalizeRemoteAssetURL(raw) ?: raw`）。
    /// `gateway` 由调用方注入（默认 `IpfsResolver.defaultGateway`）——门面按配置注入即
    /// 单次归一，不再二次归一（见 review D-2）。
    static func normalizeTokenMetadataUri(
        _ rawUri: String?,
        gateway: String = IpfsResolver.defaultGateway
    ) -> String? {
        guard let rawUri, !rawUri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return normalizeRemoteAssetURL(rawUri, baseUrl: nil, gateway: gateway) ?? rawUri
    }

    // MARK: - 工具

    /// 十进制字符串 → 大端字节（逐位 /256，支持任意长度 uint256）；非数字 → nil。
    private static func decimalStringToBytes(_ string: String) -> [UInt8]? {
        let digits = string.compactMap(\.wholeNumberValue)
        guard !digits.isEmpty, digits.count == string.count, digits.allSatisfy({ $0 >= 0 && $0 <= 9 }) else { return nil }
        var value = digits
        var bytes: [UInt8] = []
        while !value.isEmpty {
            var carry = 0
            for index in value.indices {
                let v = carry * 10 + value[index]
                value[index] = v / 256
                carry = v % 256
            }
            bytes.append(UInt8(carry))
            while value.first == 0 {
                value.removeFirst()
            }
        }
        return bytes.isEmpty ? [0] : bytes.reversed()
    }
}

private extension String {
    /// 十六进制子串索引（Swift 移植用，避免逐字符偏移样板）。
    /// 用 dropFirst/prefix 实现：越界安全（旧 index(offsetBy:) 超界会 trap，见 review P1#9）。
    subscript(range: Range<Int>) -> Substring {
        dropFirst(range.lowerBound).prefix(range.count)
    }
}
