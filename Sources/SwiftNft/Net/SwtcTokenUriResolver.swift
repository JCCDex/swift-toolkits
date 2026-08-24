import Foundation
import SwiftCore

/// SWTC `erc_info` RPC 节点提供者：返回单个 RPC URL 字符串（nil = 无可用节点 → 解析返回 nil）。
/// 对齐 Kotlin `DEFAULT_RPC_NODES`（app 侧内置）——Swift 由宿主经 init 注入，模块不内置节点。
public typealias SwtcRpcNodeProvider = @Sendable () -> String?

/// SWTC 链上元数据 URI 拉取抽象（可注入 Fake；对齐 Kotlin `SwtcNftClient` 的构造函数注入语义）。
public protocol ISwtcTokenUriResolver: Sendable {
    func fetchMetadataUri(tokenId: String) async -> String?
}

/// SWTC `erc_info` 元数据 URI 解析器（对齐 Kotlin `SwtcNftClient`）：
/// - POST `{"method":"erc_info","params":[{"tokenid": tokenId}]}`；**RPC 节点由 `getRpcNode` 注入**（单 URL）；
/// - **网络走模块 `NftHttpClient`**（`fetchRpc`：POST JSON-RPC、**跟随重定向**——对齐 Kotlin
///   `instanceFollowRedirects = true`，RPC 节点可信、属宿主注入信任面，不做 SsrfGuard 建连检查；
///   响应体上限由客户端统一）。
/// - 网关 `gateway` 供 ipfs→网关重写（SWTC 元数据 URI 常为 ipfs://）。
public struct SwtcTokenUriResolver: ISwtcTokenUriResolver {
    /// ipfs→网关重写用（SWTC 元数据 URI 常为 ipfs://），默认 defaultGateway。
    /// `let`（原为 `var` 但无人改写，见 review SwiftNft 补充细节）。
    public let gateway: String

    private let getRpcNode: SwtcRpcNodeProvider
    private let httpClient: any NftHttpClient

    public init(
        getRpcNode: @escaping SwtcRpcNodeProvider,
        httpClient: any NftHttpClient = URLSessionNftHttpClient(),
        gateway: String = IpfsResolver.defaultGateway
    ) {
        self.getRpcNode = getRpcNode
        self.httpClient = httpClient
        self.gateway = IpfsResolver.normalizedGateway(gateway)
    }

    public func fetchMetadataUri(tokenId: String) async -> String? {
        let normalized = tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let nodeUrl = self.getRpcNode() else { return nil }
        return await self.requestErcInfoMetadataUri(nodeUrl: nodeUrl, tokenId: normalized)
    }

    private func requestErcInfoMetadataUri(nodeUrl: String, tokenId: String) async -> String? {
        guard let url = URL(string: nodeUrl) else { return nil }
        let body: [String: Any] = ["method": "erc_info", "params": [["tokenid": tokenId]]]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        guard let data = try? await self.httpClient.fetchRpc(url, body: httpBody),
              let json = Json.parseObject(data)
        else { return nil }
        if json["error"] != nil {
            return nil
        }
        return Self.parseErcInfoMetadataUri(json, gateway: self.gateway)
    }

    /// 响应解析：`result.TokenInfo.TokenInfos`（JSONArray 或字符串）→ `extractSwtcMetadataUri`。
    static func parseErcInfoMetadataUri(_ response: [String: Any], gateway: String = IpfsResolver.defaultGateway) -> String? {
        guard let result = response["result"] as? [String: Any],
              let tokenInfo = result["TokenInfo"] as? [String: Any],
              let tokenInfos = tokenInfo["TokenInfos"]
        else { return nil }

        let tokenInfosJson: String = if let array = tokenInfos as? [Any] {
            Json.stringifyOrNil(array) ?? ""
        } else if let string = tokenInfos as? String, !string.isEmpty {
            string
        } else {
            Json.stringifyOrNil(tokenInfos) ?? ""
        }
        return parseSwtcMetadataUri(tokenInfosJson, gateway: gateway)
    }
}
