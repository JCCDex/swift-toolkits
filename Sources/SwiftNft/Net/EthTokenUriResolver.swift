import Foundation

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
/// - `normalizeTokenMetadataUri`：`normalizeRemoteAssetUrl(raw) ?: raw`（ipfs:// → 默认网关）；
/// - **RPC URL 由 `init(rpcUrlsForChain:)` 注入**（chainId → RPC URL 的函数），本类不内置任何端点——
///   端点属宿主配置（对应 Kotlin `AppEndpoints.RPC_*`）。
public final class EthTokenUriResolver: IEthTokenUriResolver {
    private let rpcUrlsForChain: ChainRpcUrlsProvider

    /// - Parameter rpcUrlsForChain: 根据 chainId 返回该链 RPC URL 的函数（宿主注入；nil = 无节点）。
    public init(rpcUrlsForChain: @escaping ChainRpcUrlsProvider) {
        self.rpcUrlsForChain = rpcUrlsForChain
    }

    public func resolveEthrTokenUri(contract: String, tokenId: String, chainId: Int64) async -> String? {
        guard let callData = Self.buildTokenUriCallData(tokenId: tokenId) else { return nil }
        guard let rpcUrl = self.rpcUrlsForChain(chainId) else { return nil }
        return await Self.fetchTokenUri(rpcUrl: rpcUrl, contract: contract, callData: callData)
    }

    // MARK: - eth_call

    private static func fetchTokenUri(rpcUrl: String, contract: String, callData: String) async -> String? {
        guard let url = URL(string: rpcUrl) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 对齐 Kotlin：RPC 节点可信，跟随重定向（URLSession 默认行为）
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "eth_call",
            "params": [["to": contract, "data": callData], "latest"],
            "id": 1
        ])

        guard let (body, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let rawResult = json["result"] as? String
        else { return nil }
        return Self.normalizeTokenMetadataUri(Self.decodeAbiString(rawResult))
    }

    // MARK: - calldata / 解码（对齐 Kotlin 顶层函数）

    /// `"0xc87b56dd" + tokenId(32B)`；tokenId 十进制字符串 → 任意长度 hex，失败返回 nil。
    static func buildTokenUriCallData(tokenId: String) -> String? {
        guard let bytes = decimalStringToBytes(tokenId), bytes.count <= 32 else { return nil }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
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

        guard let length = Int(normalized[64 ..< 128], radix: 16), length >= 0 else { return nil }
        let dataStart = 128
        let dataEnd = dataStart + length * 2
        guard normalized.count >= dataEnd else { return nil }

        let dataHex = String(normalized[dataStart ..< dataEnd])
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        var index = dataHex.startIndex
        while index < dataHex.endIndex {
            let next = dataHex.index(index, offsetBy: 2)
            guard let byte = UInt8(dataHex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        let value = String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// ipfs:// 等 → 默认网关；其余原样（对齐 Kotlin `normalizeRemoteAssetUrl(raw) ?: raw`）。
    static func normalizeTokenMetadataUri(_ rawUri: String?) -> String? {
        guard let rawUri, !rawUri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return normalizeRemoteAssetUrl(rawUri, baseUrl: nil) ?? rawUri
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
    subscript(range: Range<Int>) -> Substring {
        let start = index(startIndex, offsetBy: range.lowerBound)
        let end = index(start, offsetBy: range.count)
        return self[start ..< end]
    }
}
