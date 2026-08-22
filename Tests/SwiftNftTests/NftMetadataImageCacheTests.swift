@testable import SwiftNft
import XCTest

final class NftMetadataImageCacheTests: XCTestCase {
    func testSuccessIsMemoized() async {
        let cache = NftMetadataImageCache()
        let counter = LockedCounter()

        let first = await cache.getOrFetch("https://example.com/meta.json") {
            counter.increment()
            return "https://example.com/a.png"
        }
        let second = await cache.getOrFetch("https://example.com/meta.json") {
            counter.increment()
            return "https://example.com/b.png"
        }

        XCTAssertEqual(first, "https://example.com/a.png")
        XCTAssertEqual(second, "https://example.com/a.png")
        XCTAssertEqual(counter.value, 1, "命中缓存不应再次 fetch")
    }

    func testFailureIsNotCachedAndRetried() async {
        let cache = NftMetadataImageCache()
        let counter = LockedCounter()

        let first = await cache.getOrFetch("https://example.com/meta.json") {
            counter.increment()
            return nil
        }
        let second = await cache.getOrFetch("https://example.com/meta.json") {
            counter.increment()
            return "https://example.com/a.png"
        }

        XCTAssertNil(first)
        XCTAssertEqual(second, "https://example.com/a.png")
        XCTAssertEqual(counter.value, 2, "瞬时失败不缓存、下次可重试（对齐 Kotlin 测试锁定行为）")
    }

    func testConcurrentSameKeyFetchesOnce() async {
        let cache = NftMetadataImageCache()
        let counter = LockedCounter()

        // 并发 N 个同 key 调用共享同一次 fetch（Swift 对 Kotlin per-key Mutex 的显式偏离，见 02 §7）
        let results = await withTaskGroup(of: String?.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await cache.getOrFetch("https://example.com/meta.json") {
                        counter.increment()
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        return "https://example.com/a.png"
                    }
                }
            }
            var values: [String?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(Set(results), ["https://example.com/a.png"])
        XCTAssertEqual(counter.value, 1, "并发同 key 只 fetch 一次")
    }

    func testConcurrentFailureSharedSingleFetch() async {
        let cache = NftMetadataImageCache()
        let counter = LockedCounter()

        let results = await withTaskGroup(of: String?.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    await cache.getOrFetch("https://example.com/meta.json") {
                        counter.increment()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        return nil
                    }
                }
            }
            var values: [String?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results, [nil, nil, nil, nil])
        XCTAssertEqual(counter.value, 1, "并发失败共享同一个 nil（不重复拉取）")
    }

    func testBlankKeyReturnsNilWithoutFetch() async {
        let cache = NftMetadataImageCache()
        let counter = LockedCounter()
        let result = await cache.getOrFetch("   ") {
            counter.increment()
            return "https://example.com/a.png"
        }
        XCTAssertNil(result)
        XCTAssertEqual(counter.value, 0)
    }

    func testRemoveAllClearsMemoryAndCancelsInflight() async {
        let cache = NftMetadataImageCache()
        _ = await cache.getOrFetch("https://example.com/meta.json") { "https://example.com/a.png" }
        await cache.removeAll()

        // removeAll 后重新拉取（不命中旧缓存）
        let result = await cache.getOrFetch("https://example.com/meta.json") { "https://example.com/b.png" }
        XCTAssertEqual(result, "https://example.com/b.png")
    }

    func testRemoveAllDuringFetchDoesNotRepopulate() async {
        // review P1#3：fetch 在途时 removeAll()（如切账户）→ 旧结果不得回填新缓存
        let cache = NftMetadataImageCache()
        let task = Task { () -> String? in
            await cache.getOrFetch("https://example.com/meta.json") {
                try? await Task.sleep(nanoseconds: 100_000_000) // 挂起，让 removeAll 先执行
                return "stale"
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await cache.removeAll()

        let result = await task.value
        XCTAssertEqual(result, "stale", "调用方仍拿到在途结果")
        // 旧结果未被回填 → 再次 fetch 真正执行
        let second = await cache.getOrFetch("https://example.com/meta.json") { "fresh" }
        XCTAssertEqual(second, "fresh", "removeAll 后旧结果未回填，重新拉取")
    }

    func testMaxEntriesEvictsLeastRecentlyUsed() async {
        let cache = NftMetadataImageCache(maxEntries: 2)
        _ = await cache.getOrFetch("https://a.com/1") { "1" }
        _ = await cache.getOrFetch("https://a.com/2") { "2" }
        _ = await cache.getOrFetch("https://a.com/1") { "1" } // touch 1 → 2 变为最旧
        _ = await cache.getOrFetch("https://a.com/3") { "3" } // 淘汰 2

        let counter = LockedCounter()
        // 1 最近访问 → 命中（先断言——重插被淘汰的 2 会再挤掉当前最旧项，故之后不再断言 1）
        let hot = await cache.getOrFetch("https://a.com/1") { counter.increment()
            return "1b"
        }
        XCTAssertEqual(hot, "1", "最近访问的 1 命中缓存")
        XCTAssertEqual(counter.value, 0, "命中不触发重新拉取")

        // 2 已被 LRU 淘汰 → 重新拉取
        let evicted = await cache.getOrFetch("https://a.com/2") { counter.increment()
            return "2b"
        }
        XCTAssertEqual(evicted, "2b", "2 已被 LRU 淘汰，需重新拉取")
        XCTAssertEqual(counter.value, 1)
    }
}

/// 线程安全计数器（测试用）。
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        self.lock.withLock { self._value }
    }

    func increment() {
        self.lock.withLock { self._value += 1 }
    }
}
