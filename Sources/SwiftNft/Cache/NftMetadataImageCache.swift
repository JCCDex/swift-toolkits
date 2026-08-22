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
    private var accessOrder: [String] = [] // 插入序/访问序，配合 maxEntries 做简单 LRU 淘汰
    private let maxEntries: Int
    /// P1#3：`removeAll()` 递增代号；fetch 完成时若代号已变（期间清过缓存）则不回写。
    private var generation = 0

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
            self.touch(key)
            return hit
        }
        if let task = inflight[key] {
            return await task.value
        }

        let generation = self.generation
        let task = Task { await fetch() }
        self.inflight[key] = task
        defer { inflight[key] = nil }

        let result = await task.value
        // P1#3：removeAll()（如切账户）期间完成的旧 fetch 不得回填新缓存
        guard generation == self.generation else { return result }
        if let result {
            self.resolvedByMetadataUrl[key] = result
            self.accessOrder.append(key)
            while self.resolvedByMetadataUrl.count > self.maxEntries, let oldest = self.accessOrder.first {
                self.accessOrder.removeFirst()
                self.resolvedByMetadataUrl.removeValue(forKey: oldest)
            }
        }
        return result
    }

    /// 命中即刷新访问序（LRU 语义；O(n) 足够，条目数有上限）。
    private func touch(_ key: String) {
        if let index = self.accessOrder.firstIndex(of: key) {
            self.accessOrder.remove(at: index)
        }
        self.accessOrder.append(key)
    }

    public func removeAll() {
        self.generation += 1
        for task in self.inflight.values {
            task.cancel()
        }
        self.inflight.removeAll()
        self.resolvedByMetadataUrl.removeAll()
        self.accessOrder.removeAll()
    }
}
