import Foundation
import SwiftDappConnect

/// SwiftNft 配置（对应 Kotlin `NftSdk.create(context, databaseName, ethTokenUriResolver)`）。
///
/// 精简为 5 个注入点（store / ipfsGateway / httpClient / ethTokenUriResolver / swtcTokenUriResolver）：
/// - `ipfsGateway`：可注入，默认对齐 Kotlin `DEFAULT_IPFS_GATEWAY_BASE_URL`（贯穿所有 ipfs→网关重写，见 02 §4）；
/// - `ethTokenUriResolver`：EVM `tokenURI(uint256)` RPC 解析（宿主注入实现或模块默认 `EthTokenUriResolver`）；
/// - `swtcTokenUriResolver`：SWTC `erc_info` 元数据 URI 解析（宿主注入 `SwtcTokenUriResolver(getRpcNode:)` 或
///   自实现/Fake；nil = 未接入 → SWTC 元数据解析返回 nil，模块不内置节点）。
public struct SwiftNftConfig: Sendable {
    public var store: any NftStore
    public var ipfsGateway: String
    public var httpClient: any NftHttpClient
    public var ethTokenUriResolver: (any IEthTokenUriResolver)?
    public var swtcTokenUriResolver: (any ISwtcTokenUriResolver)?

    public init(
        store: any NftStore,
        ipfsGateway: String = IpfsResolver.defaultGateway,
        httpClient: any NftHttpClient = URLSessionNftHttpClient(),
        ethTokenUriResolver: (any IEthTokenUriResolver)? = nil,
        swtcTokenUriResolver: (any ISwtcTokenUriResolver)? = nil
    ) {
        self.store = store
        self.ipfsGateway = IpfsResolver.normalizedGateway(ipfsGateway)
        self.httpClient = httpClient
        self.ethTokenUriResolver = ethTokenUriResolver
        self.swtcTokenUriResolver = swtcTokenUriResolver
    }
}
