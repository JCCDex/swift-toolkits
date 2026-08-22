import Foundation

/// 本地 DID 文档存储（对齐 Kotlin `IDidStore` + `DidCoreService` 的 pending 需求）。
///
/// 自由线程（不加 @MainActor，同 DidResolver）；实现内部自行调度（GRDB 后台队列）。
/// 协议必须含 pending CRUD——否则对账状态机无法注入 Fake 测试、宿主也无法替换存储（见 Did-Swift 04 坑 #16）。
public protocol DidStore: AnyObject, Sendable {
    func observeAll() -> AsyncStream<[DidEntity]>
    func observe(_ did: String) -> AsyncStream<DidEntity?>
    func get(_ did: String) async throws -> DidEntity?
    func save(_ entity: DidEntity) async throws
    func delete(_ did: String) async throws

    // MARK: pending 对账（Swift 增强：持久化消除重启窗口，见 Did-Swift 01 §6）

    /// upsert-by-(kind, did)，**不刷新 updatedAt**（TTL 以首次写入为基准、不续期）。
    func savePending(_ pending: DidPending) async throws
    /// `(kind, did)` 联合主键唯一 → 最多一行；返回 `DidPending?`（review SwiftDid 补充细节）。
    func loadPending(kind: String, did: String) async throws -> DidPending?
    func deletePending(kind: String, did: String) async throws
    func deleteExpiredPending(now: Int64, ttlMillis: Int64) async throws
}
