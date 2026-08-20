import Foundation
import SwiftDappConnect

/// SwiftNft 配置（对应 Kotlin `NftSdk.create(context, databaseName, ethTokenUriResolver)`）。
///
/// - `ipfsGateway`：可注入，默认对齐 Kotlin `DEFAULT_IPFS_GATEWAY_BASE_URL`（贯穿所有 ipfs→网关重写，见 02 §4）；
/// - `swtcChainNftClient`：注入时**优先于** `getRpcNode`/`certificatePins`（后两者被忽略）；nil 时用后两者建默认实现；
/// - `getRpcNode`：SWTC `erc_info` 节点提供者（nil = 未配置节点 → SWTC 元数据解析返回 nil，模块不内置节点）；
/// - `ethTokenUriResolver`：EVM `tokenURI(uint256)` RPC 解析（宿主注入实现或模块默认 `EthTokenUriResolver`）。
public struct SwiftNftConfig: Sendable {
    public var store: any NftStore
    public var ipfsGateway: String
    public var httpClient: any NftHttpClient
    public var ethTokenUriResolver: (any IEthTokenUriResolver)?
    public var swtcChainNftClient: (any SwtcMetadataUriFetching)?
    public var getRpcNode: (@Sendable () -> String?)?
    public var certificatePins: [String]

    public init(
        store: any NftStore,
        ipfsGateway: String = IpfsResolver.defaultGateway,
        httpClient: any NftHttpClient = URLSessionNftHttpClient(),
        ethTokenUriResolver: (any IEthTokenUriResolver)? = nil,
        swtcChainNftClient: (any SwtcMetadataUriFetching)? = nil,
        getRpcNode: (@Sendable () -> String?)? = nil,
        certificatePins: [String] = []
    ) {
        self.store = store
        self.ipfsGateway = IpfsResolver.normalizedGateway(ipfsGateway)
        self.httpClient = httpClient
        self.ethTokenUriResolver = ethTokenUriResolver
        self.swtcChainNftClient = swtcChainNftClient
        self.getRpcNode = getRpcNode
        self.certificatePins = certificatePins
    }

    /// 生效的 SWTC 元数据拉取器：注入优先，否则用 getRpcNode/pins 建默认实现。
    func resolvedSwtcNftClient() -> any SwtcMetadataUriFetching {
        if let swtcChainNftClient {
            return swtcChainNftClient
        }
        return SwtcNftClient(
            getRpcNode: self.getRpcNode ?? { nil },
            certificatePins: self.certificatePins,
            gateway: self.ipfsGateway
        )
    }
}
