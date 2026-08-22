import GRDB
@testable import SwiftNft
import XCTest

final class GRDBNftStoreTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBNftStore!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("nft-test-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBNftStore(database: self.database)
    }

    override func tearDown() {
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        self.database = nil
        self.store = nil
    }

    /// AsyncStream 首元素（Failure == Never，无需 try；本 SDK 的 AsyncSequence 无裸 `first()`）。
    private func firstValue<Element>(_ stream: AsyncStream<Element>) async -> Element? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    // MARK: nft_meta

    func testNftMetaUpsertPreservesAutoincrementId() async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await self.store.upsertNftMeta(NftMeta(contract: "issuer", tokenId: "1", name: "first",
                                                   image: nil, tokenUri: "https://example.com/m.json",
                                                   fullContent: #"{"name":"first"}"#, updatedAt: now))

        let first = try await store.nftMeta(contract: "issuer", tokenId: "1")
        XCTAssertEqual(first?.name, "first")
        let savedID = first?.id

        // 再次 upsert：ON CONFLICT DO UPDATE 保留自增 id（对齐 Kotlin copy(id=existing.id) 语义）
        try await self.store.upsertNftMeta(NftMeta(contract: "issuer", tokenId: "1", name: "second",
                                                   image: "https://example.com/a.png", tokenUri: "https://example.com/m.json",
                                                   fullContent: #"{"name":"second"}"#, updatedAt: now + 1))
        let second = try await store.nftMeta(contract: "issuer", tokenId: "1")
        XCTAssertEqual(second?.name, "second")
        XCTAssertEqual(second?.image, "https://example.com/a.png")
        XCTAssertEqual(second?.id, savedID, "upsert 不得改变自增 id")
        let missing = try await store.nftMeta(contract: "issuer", tokenId: "2")
        XCTAssertNil(missing)
    }

    // MARK: swtc_nfts

    func testSwtcNftsUpsertObserveAndCaseInsensitiveLookup() async throws {
        let entity = SwtcNftEntity(
            ownerAddress: "JCCCC", tokenId: "1", fundCode: "FUND", fundCodeName: "Fund",
            issuer: "Issuer", tokenOwner: "JCCCC", tokenSender: "JCCCC",
            image: "https://example.com/avatar.png", name: "avatar", time: 1, block: 1, inservice: 1
        )
        try await store.upsertSwtcNfts([entity])

        // 观察（LOWER() 归一化）
        let rows = await firstValue(store.observeSwtcNfts(ownerAddress: "jcccc"))
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?.name, "avatar")

        // 大小写不敏感的 issuer 查询
        let byIssuer = try await store.swtcNftByIssuerAndTokenId(issuer: "issuer", tokenId: "1")
        XCTAssertEqual(byIssuer?.fundCode, "FUND")

        let byToken = try await store.swtcNftByTokenId(ownerAddress: "jcccc", tokenId: "1")
        XCTAssertNotNil(byToken)
    }

    func testDeleteSwtcNftsByOwnerPreservesMetadata() async throws {
        let entity = SwtcNftEntity(
            ownerAddress: "jcccc", tokenId: "1", fundCode: "FUND", fundCodeName: "Fund",
            issuer: "issuer", tokenOwner: "jcccc", tokenSender: "jcccc",
            metadataUri: "https://example.com/meta.json", image: nil, name: nil, time: 1, block: 1, inservice: 1
        )
        try await store.upsertSwtcNfts([entity])

        try await self.store.deleteSwtcNftsByOwner(ownerAddress: "jcccc")

        let deleted = try await store.swtcNftByTokenId(ownerAddress: "jcccc", tokenId: "1")
        XCTAssertNil(deleted, "持仓行已删除")
        let meta = try await store.nftMeta(contract: "issuer", tokenId: "1")
        XCTAssertEqual(meta?.tokenUri, "https://example.com/meta.json", "preserveSwtcEntityAsMeta 把 metadataUri 写进 nft_meta")
    }

    func testDeleteSwtcNftsWithoutMetadataUriDoesNotPreserve() async throws {
        let entity = SwtcNftEntity(
            ownerAddress: "jcccc", tokenId: "1", fundCode: "FUND", fundCodeName: "Fund",
            issuer: "issuer", tokenOwner: "jcccc", tokenSender: "jcccc", time: 1, block: 1, inservice: 1
        )
        try await store.upsertSwtcNfts([entity])
        try await self.store.deleteSwtcNftsByOwner(ownerAddress: "jcccc")
        let metaAfterDelete = try await store.nftMeta(contract: "issuer", tokenId: "1")
        XCTAssertNil(metaAfterDelete)
    }

    // MARK: evm_nft_items

    func testEvmNftItemsUpsertObserveAndDelete() async throws {
        let item = EvmNftItemEntity(
            chainId: "0x1", ownerAddress: "0xOwner", contractAddress: "0xABCDEF",
            tokenId: "1", imageUrl: "https://example.com/avatar.png", title: "avatar"
        )
        try await store.upsertEvmNftItems([item])

        let all = await firstValue(store.observeAllEvmNftItems(chainId: "0x1", ownerAddress: "0xowner"))
        XCTAssertEqual(all?.count, 1)
        XCTAssertEqual(all?.first?.title, "avatar")

        let byContract = try await store.evmNftItemByContractAndTokenId(chainId: "0x1", contractAddress: "0xabcdef", tokenId: "1")
        XCTAssertNotNil(byContract)

        try await self.store.deleteEvmNftItemsByCollection(chainId: "0x1", ownerAddress: "0xowner", contractAddress: "0xabcdef")
        let removedItem = try await store.evmNftItem(chainId: "0x1", ownerAddress: "0xowner", contractAddress: "0xabcdef", tokenId: "1")
        XCTAssertNil(removedItem)
    }

    // MARK: evm_nft_collections

    func testCollectionsInsertUpdateAndDelete() async throws {
        let collection = EvmNftCollectionEntity(
            chainId: "0x1", ownerAddress: "0xowner", contractAddress: "0xabcdef",
            name: "Cool Cats", symbol: "CC", tokenCount: 10
        )
        try await store.insertCollections([collection])

        let flow = await firstValue(store.observeNftCollections(chainId: "0x1", ownerAddress: "0xowner"))
        XCTAssertEqual(flow?.count, 1)
        XCTAssertEqual(flow?.first?.tokenCount, 10)

        try await self.store.updateTokenCount(chainId: "0x1", ownerAddress: "0xowner", contractAddress: "0xabcdef", tokenCount: 42)
        let updated = await firstValue(store.observeNftCollections(chainId: "0x1", ownerAddress: "0xowner"))
        XCTAssertEqual(updated?.first?.tokenCount, 42)

        try await self.store.deleteByChainAndOwner(chainId: "0x1", ownerAddress: "0xowner")
        let remainingCollections = await firstValue(store.observeNftCollections(chainId: "0x1", ownerAddress: "0xowner"))
        XCTAssertEqual(remainingCollections?.count, 0)
    }

    // MARK: 空批 upsert 幂等

    func testEmptyBatchUpsertsAreNoop() async throws {
        try await self.store.upsertSwtcNfts([])
        try await self.store.upsertEvmNftItems([])
        try await self.store.insertCollections([])
        let emptyRows = await firstValue(store.observeSwtcNfts(ownerAddress: "x"))
        XCTAssertEqual(emptyRows?.count, 0)
    }
}
