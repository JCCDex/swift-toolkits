import Foundation
import GRDB

extension DidPending: FetchableRecord, TableRecord {
    public static let databaseTableName = "did_pending"
}

/// GRDB 实现（对应 Kotlin Room `DidRoomDatabase` + `DidRoomDao` + `RoomDidStore`）。
///
/// - `did_documents` 表：自增 id 主键（对齐 Room `@PrimaryKey(autoGenerate)`）+ `did` UNIQUE 索引，
///   save 走 `INSERT ... ON CONFLICT(did) DO UPDATE`（upsert-by-did），等价「并发取最新」；对外 `DidEntity` 不暴露 id。
/// - `did_pending` 表：`(kind, did)` 联合主键，value 存 kind 相关负载，updatedAt 供 TTL 过期清理；
///   **upsert 不刷新 updatedAt**（首次写入为基准、不续期）。
/// - 观察流用 ValueObservation → AsyncStream（写后自动重放）；存储直接用 DatabasePool（WAL）。
/// @unchecked Sendable：持有的 DatabasePool 线程安全（GRDB 官方文档），见 review 三、Sendable 审计。
public final class GRDBDidStore: DidStore, @unchecked Sendable {
    private let database: DatabasePool

    public init(database: DatabasePool) throws {
        self.database = database
        try Self.migrate(database)
    }

    private static func migrate(_ database: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "did_documents") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("did", .text).notNull().unique()
                t.column("doc", .text).notNull()
                t.column("updatedAt", .integer).notNull()
            }
            try db.create(table: "did_pending") { t in
                t.column("kind", .text).notNull()
                t.column("did", .text).notNull()
                t.column("value", .text)
                t.column("updatedAt", .integer).notNull()
                t.primaryKey(["kind", "did"])
            }
        }
        try migrator.migrate(database)
    }

    // MARK: - did_documents

    public func observeAll() -> AsyncStream<[DidEntity]> {
        let observation = ValueObservation.tracking { db in
            try DidRecord.order(DidRecord.Columns.updatedAt.desc, DidRecord.Columns.id.desc).fetchAll(db)
        }
        return Self.stream(observation, in: self.database) { $0.map(\.entity) }
    }

    public func observe(_ did: String) -> AsyncStream<DidEntity?> {
        let observation = ValueObservation.tracking { db in
            try DidRecord.filter(DidRecord.Columns.did == did)
                .order(DidRecord.Columns.updatedAt.desc, DidRecord.Columns.id.desc)
                .fetchOne(db)
        }
        return Self.stream(observation, in: self.database) { $0?.entity }
    }

    public func get(_ did: String) async throws -> DidEntity? {
        try await self.database.read { db in
            try DidRecord.filter(DidRecord.Columns.did == did)
                .order(DidRecord.Columns.updatedAt.desc, DidRecord.Columns.id.desc)
                .fetchOne(db)?.entity
        }
    }

    public func save(_ entity: DidEntity) async throws {
        try await self.database.write { db in
            // upsert-by-did（对齐 Room REPLACE 语义但保留 id，避免 REPLACE 删旧插新导致自增 id 变化）
            try db.execute(
                sql: """
                INSERT INTO did_documents (did, doc, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(did) DO UPDATE SET doc = excluded.doc, updatedAt = excluded.updatedAt
                """,
                arguments: [entity.did, entity.doc, entity.updatedAt]
            )
        }
    }

    public func delete(_ did: String) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM did_documents WHERE did = ?", arguments: [did])
        }
    }

    // MARK: - did_pending

    public func savePending(_ pending: DidPending) async throws {
        try await self.database.write { db in
            // 不刷新 updatedAt：TTL 以首次写入为基准
            try db.execute(
                sql: """
                INSERT INTO did_pending (kind, did, value, updatedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind, did) DO UPDATE SET value = excluded.value
                """,
                arguments: [pending.kind, pending.did, pending.value, pending.updatedAt]
            )
        }
    }

    public func loadPending(kind: String, did: String) async throws -> [DidPending] {
        try await self.database.read { db in
            try DidPending.fetchAll(
                db,
                sql: "SELECT * FROM did_pending WHERE kind = ? AND did = ? ORDER BY updatedAt ASC",
                arguments: [kind, did]
            )
        }
    }

    public func deletePending(kind: String, did: String) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM did_pending WHERE kind = ? AND did = ?", arguments: [kind, did])
        }
    }

    public func deleteExpiredPending(now: Int64, ttlMillis: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM did_pending WHERE updatedAt < ?",
                arguments: [now - ttlMillis]
            )
        }
    }

    // MARK: - 观察流适配

    private static func stream<Value, Mapped>(
        _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
        in database: DatabasePool,
        map: @escaping @Sendable (Value) -> Mapped
    ) -> AsyncStream<Mapped> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: database) {
                        continuation.yield(map(value))
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

/// did_documents 记录（自增 id 保留在记录层，对外 `DidEntity` 不暴露）。
private struct DidRecord: Codable, FetchableRecord, TableRecord {
    var id: Int64?
    var did: String
    var doc: String
    var updatedAt: Int64

    static let databaseTableName = "did_documents"

    enum Columns {
        static let id = Column("id")
        static let did = Column("did")
        static let updatedAt = Column("updatedAt")
    }

    var entity: DidEntity {
        DidEntity(did: self.did, doc: self.doc, updatedAt: self.updatedAt)
    }
}
