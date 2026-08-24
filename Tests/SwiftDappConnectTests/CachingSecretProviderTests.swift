import Foundation
@testable import SwiftDappConnect
import Testing

@Test @MainActor func `caching secret provider reuses result within bridge window`() async throws {
    let delegate = FakeSecretProvider(privateKey: "pk")
    let provider = CachingSecretProvider(delegate: delegate, bridgeWindowMs: 500, maxAgeMs: 20000)

    let first = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
    let second = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")

    #expect(first == "pk")
    #expect(second == "pk")
    let calls = await delegate.recorder.privateKeyCalls
    #expect(calls.count == 1)
}

@Test @MainActor func `caching secret provider isolates origins and addresses`() async throws {
    let delegate = FakeSecretProvider(privateKey: "pk", secret: "sec")
    let provider = CachingSecretProvider(delegate: delegate, bridgeWindowMs: 500, maxAgeMs: 20000)

    _ = try await provider.getPrivateKeyForAddress("0x1", origin: "https://a.com")
    _ = try await provider.getPrivateKeyForAddress("0x1", origin: "https://b.com")
    _ = try await provider.getPrivateKeyForAddress("0x2", origin: "https://a.com")
    _ = try await provider.getSecretForAddress("0x1", origin: "https://a.com")
    _ = try await provider.getSecretForAddress("0x1", origin: "https://a.com")

    let privateCalls = await delegate.recorder.privateKeyCalls
    let secretCalls = await delegate.recorder.secretCalls
    #expect(privateCalls.count == 3)
    #expect(secretCalls.count == 1)
}

@Test @MainActor func `clear cache forces new delegate calls`() async throws {
    let delegate = FakeSecretProvider(privateKey: "pk")
    let provider = CachingSecretProvider(delegate: delegate, bridgeWindowMs: 500, maxAgeMs: 20000)

    _ = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
    await provider.clearCache()
    _ = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")

    let calls = await delegate.recorder.privateKeyCalls
    #expect(calls.count == 2)
}

@Test @MainActor func `clear cache during inflight cancels delegate and does not repopulate`() async throws {
    // review P1#11：in-flight 期间 clearCache → 取消委托 Task；慢委托完成也不回填缓存
    let delegate = FakeSecretProvider(privateKey: "pk", delayNanos: 80_000_000) // 80ms 慢委托
    let provider = CachingSecretProvider(delegate: delegate, bridgeWindowMs: 500, maxAgeMs: 20000)

    // 等待「委托已进入 in-flight」信号而非固定 sleep（固定 sleep 在并发负载下不可靠：
    // fetchTask 可能尚未调度，clearCache 先执行会让 generation 未变、旧结果回填 → flaky）。
    let entered = AsyncStream<Void>.makeStream()
    delegate.onDelegateEnter = { entered.continuation.yield(()) }

    let fetchTask = Task { () -> String? in
        try? await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
    }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next() // 委托已进入（80ms sleep 中）
    await provider.clearCache()

    _ = await fetchTask.value
    // clearCache 后重新拉取应再次委托（旧 in-flight 结果未被回填）
    let after = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
    #expect(after == "pk")

    let calls = await delegate.recorder.privateKeyCalls
    #expect(calls.count == 2, "in-flight 被取消/未回填，clearCache 后重新委托")
}

@Test @MainActor func `clear cache after inflight completes does not repopulate`() async throws {
    // review P1#11：in-flight 完成后（值已返回但未及回填）clearCache → 不得回填旧结果
    let delegate = FakeSecretProvider(privateKey: "pk", delayNanos: 40_000_000)
    let provider = CachingSecretProvider(delegate: delegate, bridgeWindowMs: 500, maxAgeMs: 20000)

    async let fetched = provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
    try await Task.sleep(nanoseconds: 50_000_000) // 委托已完成返回，fetch 可能已回填
    await provider.clearCache()
    let value = try await fetched
    #expect(value == "pk", "调用方仍拿到委托结果")

    // clearCache 后重新拉取：若旧结果被错误回填会命中缓存（1 次委托）；否则重新委托（2 次）
    _ = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
    let calls = await delegate.recorder.privateKeyCalls
    #expect(calls.count == 2, "clearCache 后旧结果未回填，重新委托")
}

@Test @MainActor func `cache expires after max age`() async throws {
    let delegate = FakeSecretProvider(privateKey: "pk")
    let provider = CachingSecretProvider(delegate: delegate, bridgeWindowMs: 500, maxAgeMs: 80)

    _ = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
    try await Task.sleep(nanoseconds: 120_000_000) // > 80ms maxAge
    _ = try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")

    let calls = await delegate.recorder.privateKeyCalls
    #expect(calls.count == 2)
}

@Test @MainActor func `concurrent same address delegates once`() async throws {
    let delegate = FakeSecretProvider(privateKey: "pk")
    let provider = CachingSecretProvider(delegate: delegate, bridgeWindowMs: 500, maxAgeMs: 20000)

    try await withThrowingTaskGroup(of: String?.self) { group in
        for _ in 0 ..< 5 {
            group.addTask {
                try await provider.getPrivateKeyForAddress("0x1", origin: "https://dapp.com")
            }
        }
        for try await value in group {
            #expect(value == "pk")
        }
    }

    let calls = await delegate.recorder.privateKeyCalls
    #expect(calls.count == 1)
}
