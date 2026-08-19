import Foundation
import GRDB

// MARK: - GRDB 记录适配（表结构对齐 Kotlin NftEntities.kt）

extension NftMeta: FetchableRecord, TableRecord {
    public static let databaseTableName = "nft_meta"
}

extension SwtcNftEntity: FetchableRecord, TableRecord {
    public static let databaseTableName = "swtc_nfts"
}

extension EvmNftItemEntity: FetchableRecord, TableRecord {
    public static let databaseTableName = "evm_nft_items"
}

extension EvmNftCollectionEntity: FetchableRecord, TableRecord {
    public static let databaseTableName = "evm_nft_collections"
}

/// GRDB 实现（对应 Kotlin Room `NftRoomDatabase` + `NftDao` + `NftStore`）。
///
/// - 四表 + 索引对齐 Kotlin；观察流用 ValueObservation → AsyncStream（写后自动重放）；
/// - 查询 LOWER() 归一化 address/contract（对齐 Kotlin DAO SQL）；
/// - **upsert 用 `ON CONFLICT DO UPDATE`（不用 `INSERT OR REPLACE`）**：REPLACE 删旧插新会让
///   `nft_meta` 自增 id 变化（Kotlin 为此手动 `copy(id=existing.id)`），且有行替换副作用（见 Nft-Swift 02 §5）。
public final class GRDBNftStore: NftStore, @unchecked Sendable {
    private let database: DatabasePool

    public init(database: DatabasePool) throws {
        self.database = database
        try Self.migrate(database)
    }

    // MARK: - 迁移

    private static func migrate(_ database: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "nft_meta") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contract", .text).notNull()
                t.column("tokenId", .text).notNull()
                t.column("name", .text)
                t.column("image", .text)
                t.column("tokenUri", .text)
                t.column("fullContent", .text)
                t.column("updatedAt", .integer).notNull()
                t.uniqueKey(["contract", "tokenId"])
            }
            try db.create(table: "swtc_nfts") { t in
                t.column("ownerAddress", .text).notNull().indexed()
                t.column("tokenId", .text).notNull()
                t.column("fundCode", .text).notNull()
                t.column("fundCodeName", .text).notNull()
                t.column("issuer", .text).notNull()
                t.column("tokenOwner", .text).notNull()
                t.column("tokenSender", .text).notNull()
                t.column("flags", .text)
                t.column("tokenInfos", .text)
                t.column("metadataUri", .text)
                t.column("image", .text)
                t.column("name", .text)
                t.column("description", .text)
                t.column("time", .integer).notNull()
                t.column("hash", .text)
                t.column("block", .integer).notNull()
                t.column("inservice", .integer).notNull()
                t.column("ledgerIndex", .text)
                t.column("lastUpdateTime", .integer).notNull()
                t.primaryKey(["ownerAddress", "tokenId"])
            }
            try db.create(table: "evm_nft_items") { t in
                t.column("chainId", .text).notNull().indexed()
                t.column("ownerAddress", .text).notNull().indexed()
                t.column("contractAddress", .text).notNull().indexed()
                t.column("tokenId", .text).notNull()
                t.column("objectId", .text)
                t.column("blockchainId", .integer)
                t.column("ownerTimestamp", .integer)
                t.column("imageUrl", .text)
                t.column("metadata", .text)
                t.column("tokenProtocol", .integer)
                t.column("title", .text)
                t.column("description", .text)
                t.column("updatedAt", .integer).notNull()
                t.primaryKey(["chainId", "ownerAddress", "contractAddress", "tokenId"])
            }
            try db.create(table: "evm_nft_collections") { t in
                t.column("chainId", .text).notNull().indexed()
                t.column("ownerAddress", .text).notNull().indexed()
                t.column("contractAddress", .text).notNull()
                t.column("name", .text).notNull()
                t.column("symbol", .text).notNull()
                t.column("iconUrl", .text)
                t.column("decimals", .integer).notNull()
                t.column("hid", .integer)
                t.column("blockchainId", .integer)
                t.column("tokenType", .integer)
                t.column("tokenStatus", .integer)
                t.column("tokenProtocol", .integer).notNull()
                t.column("ts", .integer)
                t.column("description", .text)
                t.column("blSymbol", .text)
                t.column("website", .text)
                t.column("priceUsd", .text)
                t.column("chg", .text)
                t.column("validated", .integer)
                t.column("gas", .integer)
                t.column("liquidity", .double)
                t.column("priceUpdateTime", .integer)
                t.column("tokenCount", .integer).notNull()
                t.primaryKey(["chainId", "ownerAddress", "contractAddress"])
            }
        }
        try migrator.migrate(database)
    }

    // MARK: - nft_meta

    public func getNftMeta(contract: String, tokenId: String) async throws -> NftMeta? {
        try await self.database.read { db in
            try NftMeta.fetchOne(db, sql: "SELECT * FROM nft_meta WHERE contract = ? AND tokenId = ? LIMIT 1",
                                 arguments: [contract, tokenId])
        }
    }

    public func upsertNftMeta(_ entity: NftMeta) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO nft_meta (contract, tokenId, name, image, tokenUri, fullContent, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(contract, tokenId) DO UPDATE SET
                    name = excluded.name, image = excluded.image, tokenUri = excluded.tokenUri,
                    fullContent = excluded.fullContent, updatedAt = excluded.updatedAt
                """,
                arguments: [entity.contract, entity.tokenId, entity.name, entity.image,
                            entity.tokenUri, entity.fullContent, entity.updatedAt]
            )
        }
    }

    // MARK: - swtc_nfts

    public func observeSwtcNfts(ownerAddress: String) -> AsyncStream<[SwtcNftEntity]> {
        let observation = ValueObservation.tracking { db in
            try SwtcNftEntity.fetchAll(
                db,
                sql: "SELECT * FROM swtc_nfts WHERE LOWER(ownerAddress) = ? ORDER BY time DESC",
                arguments: [ownerAddress.lowercased()]
            )
        }
        return Self.stream(observation, in: self.database)
    }

    public func upsertSwtcNfts(_ entities: [SwtcNftEntity]) async throws {
        guard !entities.isEmpty else { return }
        try await self.database.write { db in
            for entity in entities {
                try db.execute(
                    sql: """
                    INSERT INTO swtc_nfts (ownerAddress, tokenId, fundCode, fundCodeName, issuer, tokenOwner, tokenSender,
                                          flags, tokenInfos, metadataUri, image, name, description, time, hash, block,
                                          inservice, ledgerIndex, lastUpdateTime)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(ownerAddress, tokenId) DO UPDATE SET
                        fundCode = excluded.fundCode, fundCodeName = excluded.fundCodeName, issuer = excluded.issuer,
                        tokenOwner = excluded.tokenOwner, tokenSender = excluded.tokenSender, flags = excluded.flags,
                        tokenInfos = excluded.tokenInfos, metadataUri = excluded.metadataUri, image = excluded.image,
                        name = excluded.name, description = excluded.description, time = excluded.time, hash = excluded.hash,
                        block = excluded.block, inservice = excluded.inservice, ledgerIndex = excluded.ledgerIndex,
                        lastUpdateTime = excluded.lastUpdateTime
                    """,
                    arguments: [entity.ownerAddress, entity.tokenId, entity.fundCode, entity.fundCodeName,
                                entity.issuer, entity.tokenOwner, entity.tokenSender, entity.flags, entity.tokenInfos,
                                entity.metadataUri, entity.image, entity.name, entity.description, entity.time,
                                entity.hash, entity.block, entity.inservice, entity.ledgerIndex, entity.lastUpdateTime]
                )
            }
        }
    }

    public func getSwtcNftByIssuerAndTokenId(issuer: String, tokenId: String) async throws -> SwtcNftEntity? {
        try await self.database.read { db in
            try SwtcNftEntity.fetchOne(
                db,
                sql: "SELECT * FROM swtc_nfts WHERE LOWER(issuer) = ? AND tokenId = ? LIMIT 1",
                arguments: [issuer.lowercased(), tokenId]
            )
        }
    }

    public func getSwtcNftByTokenId(ownerAddress: String, tokenId: String) async throws -> SwtcNftEntity? {
        try await self.database.read { db in
            try SwtcNftEntity.fetchOne(
                db,
                sql: "SELECT * FROM swtc_nfts WHERE LOWER(ownerAddress) = ? AND tokenId = ? LIMIT 1",
                arguments: [ownerAddress.lowercased(), tokenId]
            )
        }
    }

    public func deleteSwtcNftsByOwner(ownerAddress: String) async throws {
        try await self.database.write { db in
            // preserveSwtcEntityAsMeta：有 metadataUri 的行写进 nft_meta，避免头像元数据随持仓删除丢失。
            let rows = try SwtcNftEntity.fetchAll(
                db,
                sql: "SELECT * FROM swtc_nfts WHERE LOWER(ownerAddress) = ?",
                arguments: [ownerAddress.lowercased()]
            )
            for entity in rows where !isBlank(entity.metadataUri) {
                let existing = try NftMeta.fetchOne(
                    db,
                    sql: "SELECT * FROM nft_meta WHERE contract = ? AND tokenId = ? LIMIT 1",
                    arguments: [entity.issuer, entity.tokenId]
                )
                if !isBlank(existing?.image) {
                    continue
                }
                try db.execute(
                    sql: """
                    INSERT INTO nft_meta (contract, tokenId, name, image, tokenUri, fullContent, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(contract, tokenId) DO UPDATE SET
                        name = excluded.name, image = excluded.image, tokenUri = excluded.tokenUri,
                        fullContent = excluded.fullContent, updatedAt = excluded.updatedAt
                    """,
                    arguments: [entity.issuer, entity.tokenId,
                                entity.name?.nilIfBlank ?? existing?.name,
                                entity.image?.nilIfBlank ?? existing?.image,
                                entity.metadataUri, existing?.fullContent,
                                Int64(Date().timeIntervalSince1970 * 1000)]
                )
            }
            try db.execute(sql: "DELETE FROM swtc_nfts WHERE LOWER(ownerAddress) = ?",
                           arguments: [ownerAddress.lowercased()])
        }
    }

    // MARK: - evm_nft_items

    public func observeEvmNftItems(chainId: String, ownerAddress: String, contractAddress: String) -> AsyncStream<[EvmNftItemEntity]> {
        let observation = ValueObservation.tracking { db in
            try EvmNftItemEntity.fetchAll(
                db,
                sql: """
                SELECT * FROM evm_nft_items
                WHERE chainId = ? AND LOWER(ownerAddress) = ? AND LOWER(contractAddress) = ?
                ORDER BY ownerTimestamp DESC
                """,
                arguments: [chainId, ownerAddress.lowercased(), contractAddress.lowercased()]
            )
        }
        return Self.stream(observation, in: self.database)
    }

    public func observeAllEvmNftItems(chainId: String, ownerAddress: String) -> AsyncStream<[EvmNftItemEntity]> {
        let observation = ValueObservation.tracking { db in
            try EvmNftItemEntity.fetchAll(
                db,
                sql: "SELECT * FROM evm_nft_items WHERE chainId = ? AND LOWER(ownerAddress) = ? ORDER BY ownerTimestamp DESC",
                arguments: [chainId, ownerAddress.lowercased()]
            )
        }
        return Self.stream(observation, in: self.database)
    }

    public func upsertEvmNftItems(_ entities: [EvmNftItemEntity]) async throws {
        guard !entities.isEmpty else { return }
        try await self.database.write { db in
            for entity in entities {
                try db.execute(
                    sql: """
                    INSERT INTO evm_nft_items (chainId, ownerAddress, contractAddress, tokenId, objectId, blockchainId,
                                              ownerTimestamp, imageUrl, metadata, tokenProtocol, title, description, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(chainId, ownerAddress, contractAddress, tokenId) DO UPDATE SET
                        objectId = excluded.objectId, blockchainId = excluded.blockchainId,
                        ownerTimestamp = excluded.ownerTimestamp, imageUrl = excluded.imageUrl,
                        metadata = excluded.metadata, tokenProtocol = excluded.tokenProtocol,
                        title = excluded.title, description = excluded.description, updatedAt = excluded.updatedAt
                    """,
                    arguments: [entity.chainId, entity.ownerAddress.lowercased(), entity.contractAddress.lowercased(),
                                entity.tokenId, entity.objectId, entity.blockchainId, entity.ownerTimestamp,
                                entity.imageUrl, entity.metadata, entity.tokenProtocol, entity.title,
                                entity.description, entity.updatedAt]
                )
            }
        }
    }

    public func getEvmNftItemByContractAndTokenId(chainId: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity? {
        try await self.database.read { db in
            try EvmNftItemEntity.fetchOne(
                db,
                sql: "SELECT * FROM evm_nft_items WHERE chainId = ? AND LOWER(contractAddress) = ? AND tokenId = ? LIMIT 1",
                arguments: [chainId, contractAddress.lowercased(), tokenId]
            )
        }
    }

    public func getEvmNftItem(chainId: String, ownerAddress: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity? {
        try await self.database.read { db in
            try EvmNftItemEntity.fetchOne(
                db,
                sql: """
                SELECT * FROM evm_nft_items
                WHERE chainId = ? AND LOWER(ownerAddress) = ? AND LOWER(contractAddress) = ? AND tokenId = ? LIMIT 1
                """,
                arguments: [chainId, ownerAddress.lowercased(), contractAddress.lowercased(), tokenId]
            )
        }
    }

    public func deleteEvmNftItemsByCollection(chainId: String, ownerAddress: String, contractAddress: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM evm_nft_items WHERE chainId = ? AND LOWER(ownerAddress) = ? AND LOWER(contractAddress) = ?",
                arguments: [chainId, ownerAddress.lowercased(), contractAddress.lowercased()]
            )
        }
    }

    // MARK: - evm_nft_collections

    public func insertCollections(_ collections: [EvmNftCollectionEntity]) async throws {
        guard !collections.isEmpty else { return }
        try await self.database.write { db in
            for collection in collections {
                try db.execute(
                    sql: """
                    INSERT INTO evm_nft_collections (chainId, ownerAddress, contractAddress, name, symbol, iconUrl, decimals,
                                                    hid, blockchainId, tokenType, tokenStatus, tokenProtocol, ts, description,
                                                    blSymbol, website, priceUsd, chg, validated, gas, liquidity,
                                                    priceUpdateTime, tokenCount)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(chainId, ownerAddress, contractAddress) DO UPDATE SET
                        name = excluded.name, symbol = excluded.symbol, iconUrl = excluded.iconUrl,
                        decimals = excluded.decimals, hid = excluded.hid, blockchainId = excluded.blockchainId,
                        tokenType = excluded.tokenType, tokenStatus = excluded.tokenStatus,
                        tokenProtocol = excluded.tokenProtocol, ts = excluded.ts, description = excluded.description,
                        blSymbol = excluded.blSymbol, website = excluded.website, priceUsd = excluded.priceUsd,
                        chg = excluded.chg, validated = excluded.validated, gas = excluded.gas,
                        liquidity = excluded.liquidity, priceUpdateTime = excluded.priceUpdateTime,
                        tokenCount = excluded.tokenCount
                    """,
                    arguments: [collection.chainId, collection.ownerAddress.lowercased(),
                                collection.contractAddress.lowercased(), collection.name, collection.symbol,
                                collection.iconUrl, collection.decimals, collection.hid, collection.blockchainId,
                                collection.tokenType, collection.tokenStatus, collection.tokenProtocol, collection.ts,
                                collection.description, collection.blSymbol, collection.website, collection.priceUsd,
                                collection.chg, collection.validated, collection.gas, collection.liquidity,
                                collection.priceUpdateTime, collection.tokenCount]
                )
            }
        }
    }

    public func getNftCollectionsFlow(chainId: String, ownerAddress: String) -> AsyncStream<[EvmNftCollectionEntity]> {
        let observation = ValueObservation.tracking { db in
            try EvmNftCollectionEntity.fetchAll(
                db,
                sql: "SELECT * FROM evm_nft_collections WHERE chainId = ? AND LOWER(ownerAddress) = ? ORDER BY ts DESC",
                arguments: [chainId, ownerAddress.lowercased()]
            )
        }
        return Self.stream(observation, in: self.database)
    }

    public func deleteByChainAndOwner(chainId: String, ownerAddress: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM evm_nft_collections WHERE chainId = ? AND LOWER(ownerAddress) = ?",
                arguments: [chainId, ownerAddress.lowercased()]
            )
        }
    }

    public func updateTokenCount(chainId: String, ownerAddress: String, contractAddress: String, tokenCount: Int) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE evm_nft_collections SET tokenCount = ? WHERE chainId = ? AND LOWER(ownerAddress) = ? AND LOWER(contractAddress) = ?",
                arguments: [tokenCount, chainId, ownerAddress.lowercased(), contractAddress.lowercased()]
            )
        }
    }

    // MARK: - 观察流适配（ValueObservation → AsyncStream）

    private static func stream<T: Sendable>(_ observation: ValueObservation<ValueReducers.Fetch<T>>, in database: DatabasePool) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: database) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
