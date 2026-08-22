import Foundation

/// 异步记忆化缓存（通用：图片解析结果 / eth_call 结果等按 key 缓存 String? 结果；
/// 原 SwiftNft `NftMetadataImageCache` 并入 SwiftCore 通用化，见 review D-1）：
/// - key = 规范化后的字符串（trim）；
/// - **只缓存成功（非 nil）结果**；瞬时失败不落缓存，下次调用重新拉取（Kotlin 测试锁定）；
/// - **per-key Task in-flight 去重**：同 key 并发只执行一次 fetch（N 个并发调用共享同一个结果——
///   这是对 Kotlin per-key Mutex 的显式偏离：Kotlin 在并发失败时 N 并发 = N 次拉取，Swift 共享同一个 nil，
///   勿为「对齐 Kotlin」复刻重复拉取，见 Nft-Swift 02 §7 / 04 坑 #16）；
/// - `removeAll()` 必须取消在途 Task 并清空两字典（否则切账户后旧请求继续回写缓存）；
/// - 内存条数上限（Swift 轻量增强：Kotlin 无上限，长生命周期按 key 累积会无界增长）。
public actor AsyncMemoCache {
    private var resolved: [String: String] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]
    private var accessOrder: [String] = [] // 插入序/访问序，配合 maxEntries 做简单 LRU 淘汰
    private let maxEntries: Int
    /// P1#3：`removeAll()` 递增代号；fetch 完成时若代号已变（期间清过缓存）则不回写。
    private var generation = 0

    public init(maxEntries: Int = 256) {
        self.maxEntries = maxEntries
    }

    public func getOrFetch(
        _ key: String,
        fetch: @escaping @Sendable () async -> String?
    ) async -> String? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return nil }

        if let hit = resolved[normalizedKey] {
            self.touch(normalizedKey)
            return hit
        }
        if let task = inflight[normalizedKey] {
            return await task.value
        }

        let generation = self.generation
        let task = Task { await fetch() }
        self.inflight[normalizedKey] = task
        defer { inflight[normalizedKey] = nil }

        let result = await task.value
        // P1#3：removeAll()（如切账户）期间完成的旧 fetch 不得回填新缓存
        guard generation == self.generation else { return result }
        if let result {
            self.resolved[normalizedKey] = result
            self.accessOrder.append(normalizedKey)
            while self.resolved.count > self.maxEntries, let oldest = self.accessOrder.first {
                self.accessOrder.removeFirst()
                self.resolved.removeValue(forKey: oldest)
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
        self.resolved.removeAll()
        self.accessOrder.removeAll()
    }
}
