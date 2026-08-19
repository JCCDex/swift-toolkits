import Foundation

/// 图片解析结果记忆化缓存（对齐 Kotlin `NftMetadataImageCache`）：
/// - key = 规范化后的 metadataUrl（trim）；
/// - **只缓存成功（非 nil）结果**；瞬时失败不落缓存，下次调用重新拉取（Kotlin 测试锁定）；
/// - **per-key Task in-flight 去重**：同 key 并发只执行一次 fetch（N 个并发调用共享同一个结果——
///   这是对 Kotlin per-key Mutex 的显式偏离：Kotlin 在并发失败时 N 并发 = N 次拉取，Swift 共享同一个 nil，
///   勿为「对齐 Kotlin」复刻重复拉取，见 Nft-Swift 02 §7 / 04 坑 #16）；
/// - `removeAll()` 必须取消在途 Task 并清空两字典（否则切账户后旧请求继续回写缓存）；
/// - 内存条数上限（Swift 轻量增强：Kotlin 无上限，长生命周期按 metadataUrl 累积会无界增长）。
public actor NftMetadataImageCache {
    private var resolvedByMetadataUrl: [String: String] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 256) {
        self.maxEntries = maxEntries
    }

    public func getOrFetch(
        _ metadataUrl: String,
        fetch: @escaping @Sendable () async -> String?
    ) async -> String? {
        let key = metadataUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        if let hit = resolvedByMetadataUrl[key] {
            return hit
        }
        if let task = inflight[key] {
            return await task.value
        }

        let task = Task { await fetch() }
        self.inflight[key] = task
        defer { inflight[key] = nil }

        let result = await task.value
        if let result {
            self.resolvedByMetadataUrl[key] = result
            if self.resolvedByMetadataUrl.count > self.maxEntries, let oldest = resolvedByMetadataUrl.keys.first {
                self.resolvedByMetadataUrl.removeValue(forKey: oldest) // 简单条数上限（非严格 LRU）
            }
        }
        return result
    }

    public func removeAll() {
        for task in self.inflight.values {
            task.cancel()
        }
        self.inflight.removeAll()
        self.resolvedByMetadataUrl.removeAll()
    }
}
