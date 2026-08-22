import Foundation

/// 持仓/元数据存储（对齐 Kotlin `NftStore` 方法面）。
///
/// 显式偏离（见 Nft-Swift 02 §5）：解析/编排逻辑（resolveSwtcAvatar 等）归属 NftClient 门面，
/// 本协议保持**纯存储、可替换**——宿主自实现存储时无需连带实现解析。
///
/// `Sendable`（Swift 6 严格并发）：`NftClient: Sendable` / `SwiftNftConfig: Sendable` 持有
/// `any NftStore`，协议必须 Sendable（GRDB 实现基于线程安全的 DatabasePool，标 `@unchecked Sendable`）。
public protocol NftStore: AnyObject, Sendable {

    // MARK: 元数据缓存表 nft_meta（(contract, tokenId) UNIQUE）

    func nftMeta(contract: String, tokenId: String) async throws -> NftMeta?
    func upsertNftMeta(_ entity: NftMeta) async throws

    // MARK: SWTC 持仓表 swtc_nfts（(ownerAddress, tokenId) 复合 PK）

    func observeSwtcNfts(ownerAddress: String) -> AsyncStream<[SwtcNftEntity]>
    func upsertSwtcNfts(_ entities: [SwtcNftEntity]) async throws
    func swtcNftByIssuerAndTokenId(issuer: String, tokenId: String) async throws -> SwtcNftEntity?
    func swtcNftByTokenId(ownerAddress: String, tokenId: String) async throws -> SwtcNftEntity?
    /// 删除前先 preserveSwtcEntityAsMeta（有 metadataUri 的行写进 nft_meta，防头像元数据随持仓删除丢失）。
    func deleteSwtcNftsByOwner(ownerAddress: String) async throws

    // MARK: EVM 持仓表 evm_nft_items（四列复合 PK）

    func observeEvmNftItems(chainId: String, ownerAddress: String, contractAddress: String) -> AsyncStream<[EvmNftItemEntity]>
    func observeAllEvmNftItems(chainId: String, ownerAddress: String) -> AsyncStream<[EvmNftItemEntity]>
    func upsertEvmNftItems(_ entities: [EvmNftItemEntity]) async throws
    func evmNftItemByContractAndTokenId(chainId: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity?
    func evmNftItem(chainId: String, ownerAddress: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity?
    func deleteEvmNftItemsByCollection(chainId: String, ownerAddress: String, contractAddress: String) async throws

    // MARK: EVM 集合表 evm_nft_collections（三列复合 PK）

    func insertCollections(_ collections: [EvmNftCollectionEntity]) async throws
    func observeNftCollections(chainId: String, ownerAddress: String) -> AsyncStream<[EvmNftCollectionEntity]>
    func deleteByChainAndOwner(chainId: String, ownerAddress: String) async throws
    func updateTokenCount(chainId: String, ownerAddress: String, contractAddress: String, tokenCount: Int) async throws
}
