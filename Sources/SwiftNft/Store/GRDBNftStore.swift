import Foundation
import GRDB
import OSLog
import SwiftCore

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
/// - 地址/合约写入归一为小写、查询不再 `LOWER()`（v2/v3 起，对齐 Kotlin DAO `COLLATE NOCASE`
///   语义，且让列索引生效，见 review 存储/索引项 C-1）；
/// - **upsert 用 `ON CONFLICT DO UPDATE`（不用 `INSERT OR REPLACE`）**：REPLACE 删旧插新会让
///   `nft_meta` 自增 id 变化（Kotlin 为此手动 `copy(id=existing.id)`），且有行替换副作用（见 Nft-Swift 02 §5）。
/// @unchecked Sendable：持有的 DatabasePool 线程安全（GRDB 官方文档），见 review 三、Sendable 审计。
public final class GRDBNftStore: NftStore, @unchecked Sendable {
    private let database: DatabasePool
    private static let logger = Logger(subsystem: "com.jccdex.toolkits.swiftnft", category: "GRDBNftStore")

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
        // v2（review P1#4）：swtc_nfts 旧行统一小写（新写入在 upsertSwtcNfts 归一），
        // 查询去掉 LOWER() 使 ownerAddress 索引生效；issuer 补索引（swtcNftByIssuerAndTokenId 用）。
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "UPDATE swtc_nfts SET ownerAddress = LOWER(ownerAddress), issuer = LOWER(issuer)")
            try db.create(index: "idx_swtc_nfts_issuer", on: "swtc_nfts", columns: ["issuer"])
        }
        // v3（review C-1）：EVM 两表旧行统一小写（新写入在 upsertEvmNftItems/insertCollections 已归一），
        // 查询去掉 LOWER() 使 ownerAddress/contractAddress 索引生效。
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "UPDATE evm_nft_items SET ownerAddress = LOWER(ownerAddress), contractAddress = LOWER(contractAddress)")
            try db.execute(sql: "UPDATE evm_nft_collections SET ownerAddress = LOWER(ownerAddress), contractAddress = LOWER(contractAddress)")
        }
        try migrator.migrate(database)
    }

    // MARK: - nft_meta

    public func nftMeta(contract: String, tokenId: String) async throws -> NftMeta? {
        try await self.database.read { db in
            // 头像解析只需 name/image/tokenUri：投影去掉可能达 2 MiB 的 fullContent（review P1#6）
            try NftMeta.fetchOne(db, sql: "SELECT contract, tokenId, name, image, tokenUri, updatedAt FROM nft_meta WHERE contract = ? AND tokenId = ? LIMIT 1",
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
                sql: "SELECT * FROM swtc_nfts WHERE ownerAddress = ? ORDER BY time DESC",
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
                    arguments: [entity.ownerAddress.lowercased(), entity.tokenId, entity.fundCode, entity.fundCodeName,
                                entity.issuer.lowercased(), entity.tokenOwner, entity.tokenSender, entity.flags, entity.tokenInfos,
                                entity.metadataUri, entity.image, entity.name, entity.description, entity.time,
                                entity.hash, entity.block, entity.inservice, entity.ledgerIndex, entity.lastUpdateTime]
                )
            }
        }
    }

    public func swtcNftByIssuerAndTokenId(issuer: String, tokenId: String) async throws -> SwtcNftEntity? {
        try await self.database.read { db in
            try SwtcNftEntity.fetchOne(
                db,
                sql: "SELECT * FROM swtc_nfts WHERE issuer = ? AND tokenId = ? LIMIT 1",
                arguments: [issuer.lowercased(), tokenId]
            )
        }
    }

    public func swtcNftByTokenId(ownerAddress: String, tokenId: String) async throws -> SwtcNftEntity? {
        try await self.database.read { db in
            try SwtcNftEntity.fetchOne(
                db,
                sql: "SELECT * FROM swtc_nfts WHERE ownerAddress = ? AND tokenId = ? LIMIT 1",
                arguments: [ownerAddress.lowercased(), tokenId]
            )
        }
    }

    public func deleteSwtcNftsByOwner(ownerAddress: String) async throws {
        let owner = ownerAddress.lowercased() // v2 起写入已小写，查询不再 LOWER()
        try await self.database.write { db in
            // preserveSwtcEntityAsMeta：有 metadataUri 的行写进 nft_meta，避免头像元数据随持仓删除丢失。
            let rows = try SwtcNftEntity.fetchAll(
                db,
                sql: "SELECT * FROM swtc_nfts WHERE ownerAddress = ?",
                arguments: [owner]
            )
            // P1#5：一次性批量查 nft_meta（原实现逐行查询 = N+1）
            let toPreserve = rows.filter { !isBlank($0.metadataUri) }
            var existingByKey: [String: NftMeta] = [:]
            if !toPreserve.isEmpty {
                let tuplePlaceholders = Array(repeating: "(?, ?)", count: toPreserve.count).joined(separator: ",")
                let metas = try NftMeta.fetchAll(
                    db,
                    sql: "SELECT contract, tokenId, image, fullContent FROM nft_meta WHERE (contract, tokenId) IN (\(tuplePlaceholders))",
                    arguments: StatementArguments(toPreserve.flatMap { [$0.issuer, $0.tokenId] })
                )
                existingByKey = Dictionary(uniqueKeysWithValues: metas.map { ("\($0.contract)|\($0.tokenId)", $0) })
            }
            for entity in toPreserve {
                let existing = existingByKey["\(entity.issuer)|\(entity.tokenId)"]
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
                                Date.nowMillis()]
                )
            }
            try db.execute(sql: "DELETE FROM swtc_nfts WHERE ownerAddress = ?", arguments: [owner])
        }
    }

    // MARK: - evm_nft_items

    public func observeEvmNftItems(chainId: String, ownerAddress: String, contractAddress: String) -> AsyncStream<[EvmNftItemEntity]> {
        let observation = ValueObservation.tracking { db in
            try EvmNftItemEntity.fetchAll(
                db,
                sql: """
                SELECT * FROM evm_nft_items
                WHERE chainId = ? AND ownerAddress = ? AND contractAddress = ?
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
                sql: "SELECT * FROM evm_nft_items WHERE chainId = ? AND ownerAddress = ? ORDER BY ownerTimestamp DESC",
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

    public func evmNftItemByContractAndTokenId(chainId: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity? {
        try await self.database.read { db in
            try EvmNftItemEntity.fetchOne(
                db,
                sql: "SELECT * FROM evm_nft_items WHERE chainId = ? AND contractAddress = ? AND tokenId = ? LIMIT 1",
                arguments: [chainId, contractAddress.lowercased(), tokenId]
            )
        }
    }

    public func evmNftItem(chainId: String, ownerAddress: String, contractAddress: String, tokenId: String) async throws -> EvmNftItemEntity? {
        try await self.database.read { db in
            try EvmNftItemEntity.fetchOne(
                db,
                sql: """
                SELECT * FROM evm_nft_items
                WHERE chainId = ? AND ownerAddress = ? AND contractAddress = ? AND tokenId = ? LIMIT 1
                """,
                arguments: [chainId, ownerAddress.lowercased(), contractAddress.lowercased(), tokenId]
            )
        }
    }

    public func deleteEvmNftItemsByCollection(chainId: String, ownerAddress: String, contractAddress: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM evm_nft_items WHERE chainId = ? AND ownerAddress = ? AND contractAddress = ?",
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

    public func observeNftCollections(chainId: String, ownerAddress: String) -> AsyncStream<[EvmNftCollectionEntity]> {
        let observation = ValueObservation.tracking { db in
            try EvmNftCollectionEntity.fetchAll(
                db,
                sql: "SELECT * FROM evm_nft_collections WHERE chainId = ? AND ownerAddress = ? ORDER BY ts DESC",
                arguments: [chainId, ownerAddress.lowercased()]
            )
        }
        return Self.stream(observation, in: self.database)
    }

    public func deleteByChainAndOwner(chainId: String, ownerAddress: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM evm_nft_collections WHERE chainId = ? AND ownerAddress = ?",
                arguments: [chainId, ownerAddress.lowercased()]
            )
        }
    }

    public func updateTokenCount(chainId: String, ownerAddress: String, contractAddress: String, tokenCount: Int) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE evm_nft_collections SET tokenCount = ? WHERE chainId = ? AND ownerAddress = ? AND contractAddress = ?",
                arguments: [tokenCount, chainId, ownerAddress.lowercased(), contractAddress.lowercased()]
            )
        }
    }

    // MARK: - 观察流适配（ValueObservation → AsyncStream）

    /// - 值去重：每次写都会重发射，值未变时跳过（等价 removeDuplicates；AsyncValueObservation
    ///   非泛型 AsyncSequence，手动比较上一个值——review SwiftNft 补充细节）
    /// - `.bufferingNewest(1)`：观察流消费者取最新值，无界缓冲无意义（默认无界会积压）
    /// - 观察出错：记日志后 finish（原实现静默结束，消费方无从得知流死亡）
    private static func stream<T: Sendable & Equatable>(_ observation: ValueObservation<ValueReducers.Fetch<T>>, in database: DatabasePool) -> AsyncStream<T> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var lastValue: T?
                do {
                    for try await value in observation.values(in: database) {
                        if lastValue == value {
                            continue
                        }
                        lastValue = value
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    Self.logger.error("nft observation stream failed: \(error)")
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
