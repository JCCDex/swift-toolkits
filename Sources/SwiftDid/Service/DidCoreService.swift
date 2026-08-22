import Foundation
import SwiftCore

/// 观察/取档/写操作编排 + pending 对账状态机（对应 Kotlin `DidCoreService`，见 Did-Swift 01 §6）。
///
/// **Swift 修正（勿照搬 Kotlin）**：
/// 1. `updated` 用 ISO8601 `Date` 比较（Kotlin 字符串比较在精度不齐时判错）；
/// 2. `resolveAndSaveDid` 返回三态 `DidResolveOutcome`，桥/网络错误不伪装成 missing；
/// 3. 删除防复活：`pendingDelete` 检查前置到「localDoc == nil 的 upsert」之前（Kotlin 死代码陷阱）；
/// 4. 四张 pending 表合并为 `did_pending` 单表（kind 列）持久化到 GRDB，消除重启窗口；TTL 24h、
///    首次写入为基准不续期、按 kind 确认才清除、过期失效。
@MainActor
final class DidCoreService {
    static let pendingCreate = "create"
    static let pendingAvatar = "avatar"
    static let pendingNickname = "nickname"
    static let pendingDelete = "delete"

    static let pendingTTLMillis: Int64 = 24 * 60 * 60 * 1000

    private let store: any DidStore
    private let resolver: any DidResolver

    init(store: any DidStore, resolver: any DidResolver) {
        self.store = store
        self.resolver = resolver
    }

    // MARK: - 观察

    func observeAll() -> AsyncStream<[DidEntity]> {
        self.store.observeAll()
    }

    func observe(_ did: String) -> AsyncStream<DidEntity?> {
        self.store.observe(did)
    }

    // MARK: - 链上解析 + 落库 + 对账

    /// **不 throw**：失败统一进 `.error`，调用方按三态 switch 决策（见 DidModels.DidResolveOutcome）。
    func resolveAndSaveDid(_ did: String) async -> DidResolveOutcome {
        do {
            let localDoc = try await store.get(did)
            let chainDoc: String
            do {
                chainDoc = try await self.resolver.resolve(did)
            } catch {
                return .error(error) // 桥/网络错误不得伪装成「链上缺失」
            }

            if Json.isEmpty(chainDoc) {
                return await self.handleMissingChainDocument(did, localDoc)
            }

            // 删除防复活（Swift 修正 #3）：链上旧文档仍服务且 `updated == 删除时间戳` → 不复活、清表、返回缺失。
            // 必须**先于**下方 `localDoc == nil` 的 upsert 分支执行，否则已删除 DID 会被旧文档复活。
            if let chainUpdated = DidJson.extractUpdated(chainDoc),
               let pendingDelete = try? await store.loadPending(kind: Self.pendingDelete, did: did),
               chainUpdated == pendingDelete.value {
                try? await self.store.deletePending(kind: Self.pendingDelete, did: did)
                return .missing
            }

            guard let localDoc else {
                try await self.store.save(DidEntity(did: did, doc: chainDoc, updatedAt: Self.nowMillis()))
                return .document(chainDoc)
            }

            // avatar pending：链上头像未刷新到 pending 值 → 保护本地
            if let pendingAvatar = try? await store.loadPending(kind: Self.pendingAvatar, did: did) {
                let chainAvatar = DidJson.readProfileField(chainDoc, "preferredAvatar")
                if chainAvatar != pendingAvatar.value {
                    return .document(localDoc.doc)
                }
                try? await self.store.deletePending(kind: Self.pendingAvatar, did: did)
            }
            // nickname pending：同上
            if let pendingNickname = try? await store.loadPending(kind: Self.pendingNickname, did: did) {
                let chainNickname = DidJson.readProfileField(chainDoc, "nickname")
                if chainNickname != pendingNickname.value {
                    return .document(localDoc.doc)
                }
                try? await self.store.deletePending(kind: Self.pendingNickname, did: did)
            }

            // `updated` 比较（Swift 修正 #1：Date，勿字符串比较）
            let localUpdated = DidJson.extractUpdated(localDoc.doc).flatMap { Date.parseISO8601($0) }
            let chainUpdated = DidJson.extractUpdated(chainDoc).flatMap { Date.parseISO8601($0) }
            if let chainUpdated, localUpdated.map({ chainUpdated > $0 }) ?? true {
                try await self.store.save(DidEntity(did: did, doc: chainDoc, updatedAt: Self.nowMillis()))
                return .document(chainDoc)
            }
            return .document(localDoc.doc)
        } catch {
            return .error(error)
        }
    }

    private func handleMissingChainDocument(_ did: String, _ localDoc: DidEntity?) async -> DidResolveOutcome {
        // create pending 命中：初始 DID 刚发布、链上尚未可见 → 保留本地
        if let _ = try? await store.loadPending(kind: Self.pendingCreate, did: did) {
            try? await self.store.deletePending(kind: Self.pendingCreate, did: did)
            return localDoc.map { .document($0.doc) } ?? .missing
        }
        // delete pending 命中：链上缺失（tombstone 已传播）→ 删除已确认，清表
        if let _ = try? await store.loadPending(kind: Self.pendingDelete, did: did) {
            try? await self.store.deletePending(kind: Self.pendingDelete, did: did)
        }
        try? await self.store.delete(did)
        return .missing
    }

    // MARK: - 取档 / 写操作

    func getDidDocument(_ did: String) async throws -> DidEntity? {
        try await self.store.get(did)
    }

    func deleteDidDocument(_ did: String, deletedDoc: String?) async throws {
        if let doc = deletedDoc, let updated = DidJson.extractUpdated(doc) {
            try await self.store.savePending(DidPending(kind: Self.pendingDelete, did: did, value: updated, updatedAt: Self.nowMillis()))
        }
        try await self.store.delete(did)
    }

    func saveNewCreatedDid(_ did: String, doc: String) async throws {
        try await self.saveDocumentWithPending(did, doc, kind: Self.pendingCreate)
    }

    func saveNewAvatarDid(_ did: String, doc: String) async throws {
        try await self.saveDocumentWithPending(did, doc, kind: Self.pendingAvatar)
    }

    func saveNewNicknameDid(_ did: String, doc: String) async throws {
        try await self.saveDocumentWithPending(did, doc, kind: Self.pendingNickname)
    }

    func saveDidDocument(_ did: String, doc: String) async throws {
        try await self.store.save(DidEntity(did: did, doc: doc, updatedAt: Self.nowMillis()))
    }

    private func saveDocumentWithPending(_ did: String, _ doc: String, kind: String) async throws {
        let value: String? = switch kind {
        case Self.pendingAvatar:
            DidJson.readProfileField(doc, "preferredAvatar")
        case Self.pendingNickname:
            DidJson.readProfileField(doc, "nickname")
        default:
            nil
        }
        try await self.store.savePending(DidPending(kind: kind, did: did, value: value, updatedAt: Self.nowMillis()))
        try await self.store.save(DidEntity(did: did, doc: doc, updatedAt: Self.nowMillis()))
    }

    func deleteExpiredPending(now: Int64, ttlMillis: Int64) async throws {
        try await self.store.deleteExpiredPending(now: now, ttlMillis: ttlMillis)
    }

    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
