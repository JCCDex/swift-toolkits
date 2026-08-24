import Foundation
import OSLog
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

    private static let logger = Logger(subsystem: "com.jccdex.toolkits.swiftdid", category: "DidCoreService")

    private let store: any DidStore
    private let resolver: any DidResolver

    init(store: any DidStore, resolver: any DidResolver) {
        self.store = store
        self.resolver = resolver
    }

    /// 写路径失败日志（对齐 `SwiftDid.logWriteError` 隐私纪律：NSError 只打 domain#code，
    /// 纯枚举打 case 名，不落 payload——见 review 六 V-4）。
    private func logError(_ operation: String, error: Error, did: String?) {
        let summary = if let nsError = error as NSError? {
            "\(nsError.domain)#\(nsError.code)"
        } else {
            String(describing: error)
        }
        let didSuffix = did.map { " did=\($0)" } ?? ""
        Self.logger.error("\(operation, privacy: .public) failed: \(summary, privacy: .public)\(didSuffix, privacy: .public)")
    }

    /// pending 读取（对账分支内失败降级 nil + 记日志——失败会让「删除防复活/头像保护」
    /// 检查失效，必须可观测，见 review 六 V-4）。
    private func loadPendingLogging(kind: String, did: String) async -> DidPending? {
        do {
            return try await self.store.loadPending(kind: kind, did: did)
        } catch {
            self.logError("loadPending(\(kind))", error: error, did: did)
            return nil
        }
    }

    /// pending 清理（对账分支内失败降级 + 记日志——清理失败会泄漏 pending 状态，见 review 六 V-4）。
    private func deletePendingLogging(kind: String, did: String) async {
        do {
            try await self.store.deletePending(kind: kind, did: did)
        } catch {
            self.logError("deletePending(\(kind))", error: error, did: did)
        }
    }

    /// 本地文档删除（`handleMissingChainDocument` 收尾；失败降级 + 记日志）。
    private func deleteDidLogging(_ did: String) async {
        do {
            try await self.store.delete(did)
        } catch {
            self.logError("delete", error: error, did: did)
        }
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
               let pendingDelete = await self.loadPendingLogging(kind: Self.pendingDelete, did: did),
               chainUpdated == pendingDelete.value {
                await self.deletePendingLogging(kind: Self.pendingDelete, did: did)
                return .missing
            }

            guard let localDoc else {
                try await self.store.save(DidEntity(did: did, doc: chainDoc, updatedAt: Date.nowMillis()))
                return .document(chainDoc)
            }

            // avatar pending：链上头像未刷新到 pending 值 → 保护本地
            if let pendingAvatar = await self.loadPendingLogging(kind: Self.pendingAvatar, did: did) {
                let chainAvatar = DidJson.readProfileField(chainDoc, "preferredAvatar")
                if chainAvatar != pendingAvatar.value {
                    return .document(localDoc.doc)
                }
                await self.deletePendingLogging(kind: Self.pendingAvatar, did: did)
            }
            // nickname pending：同上
            if let pendingNickname = await self.loadPendingLogging(kind: Self.pendingNickname, did: did) {
                let chainNickname = DidJson.readProfileField(chainDoc, "nickname")
                if chainNickname != pendingNickname.value {
                    return .document(localDoc.doc)
                }
                await self.deletePendingLogging(kind: Self.pendingNickname, did: did)
            }

            // `updated` 比较（Swift 修正 #1：Date，勿字符串比较）
            let localUpdated = DidJson.extractUpdated(localDoc.doc).flatMap { Date.parseISO8601($0) }
            let chainUpdated = DidJson.extractUpdated(chainDoc).flatMap { Date.parseISO8601($0) }
            if let chainUpdated, localUpdated.map({ chainUpdated > $0 }) ?? true {
                try await self.store.save(DidEntity(did: did, doc: chainDoc, updatedAt: Date.nowMillis()))
                return .document(chainDoc)
            }
            return .document(localDoc.doc)
        } catch {
            return .error(error)
        }
    }

    private func handleMissingChainDocument(_ did: String, _ localDoc: DidEntity?) async -> DidResolveOutcome {
        // create pending 命中：初始 DID 刚发布、链上尚未可见 → 保留本地
        if let _ = await self.loadPendingLogging(kind: Self.pendingCreate, did: did) {
            await self.deletePendingLogging(kind: Self.pendingCreate, did: did)
            return localDoc.map { .document($0.doc) } ?? .missing
        }
        // delete pending 命中：链上缺失（tombstone 已传播）→ 删除已确认，清表
        if let _ = await self.loadPendingLogging(kind: Self.pendingDelete, did: did) {
            await self.deletePendingLogging(kind: Self.pendingDelete, did: did)
        }
        await self.deleteDidLogging(did)
        return .missing
    }

    // MARK: - 取档 / 写操作

    func getDidDocument(_ did: String) async throws -> DidEntity? {
        try await self.store.get(did)
    }

    func deleteDidDocument(_ did: String, deletedDoc: String?) async throws {
        if let doc = deletedDoc, let updated = DidJson.extractUpdated(doc) {
            try await self.store.savePending(DidPending(kind: Self.pendingDelete, did: did, value: updated, updatedAt: Date.nowMillis()))
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
        try await self.store.save(DidEntity(did: did, doc: doc, updatedAt: Date.nowMillis()))
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
        try await self.store.savePending(DidPending(kind: kind, did: did, value: value, updatedAt: Date.nowMillis()))
        try await self.store.save(DidEntity(did: did, doc: doc, updatedAt: Date.nowMillis()))
    }

    func deleteExpiredPending(now: Int64, ttlMillis: Int64) async throws {
        try await self.store.deleteExpiredPending(now: now, ttlMillis: ttlMillis)
    }
}
