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
