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
