import GRDB
@testable import SwiftDid
import XCTest

/// DidCoreService 对账状态机测试（GRDB 内存/临时文件库 + Fake resolver；覆盖 Swift 修正：
/// updated 按 Date 比较、三态结果、删除防复活前置、pending 持久化 TTL）。
@MainActor
final class DidCoreServiceTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBDidStore!
    private var resolver: FakeDidResolver!
    private var core: DidCoreService!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("did-core-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBDidStore(database: self.database)
        self.resolver = FakeDidResolver()
        self.core = DidCoreService(store: self.store, resolver: self.resolver)
    }

    override func tearDown() {
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        self.database = nil
        self.store = nil
        self.resolver = nil
        self.core = nil
    }

    private func saveLocal(_ did: String, doc: String, updatedAt: Int64 = 1000) async throws {
        try await self.store.save(DidEntity(did: did, doc: doc, updatedAt: updatedAt))
    }

    private func doc(updated: String) -> String {
        #"{"updated":"\#(updated)"}"#
    }

    // MARK: - 基本解析

    func testResolveAndSaveNewDocument() async throws {
        self.resolver.setResult(self.doc(updated: "2025-01-02T00:00:00.000Z"))
        let outcome = await core.resolveAndSaveDid("did:ethr:0xaaa")
        guard case let .document(chainDoc) = outcome else {
            return XCTFail("应为 document，实际 \(outcome)")
        }
        XCTAssertEqual(chainDoc, self.doc(updated: "2025-01-02T00:00:00.000Z"))
        let saved = try await store.get("did:ethr:0xaaa")
        XCTAssertEqual(saved?.doc, chainDoc, "新文档应落库")
    }

    func testResolveAndSaveChainNewerThanLocal() async throws {
        try await self.saveLocal("did:swtc:aaa", doc: self.doc(updated: "2025-01-01T00:00:00.000Z"), updatedAt: 1)
        self.resolver.setResult(self.doc(updated: "2025-01-02T00:00:00.000Z"))
        let outcome = await core.resolveAndSaveDid("did:swtc:aaa")
        guard case let .document(chainDoc) = outcome else { return XCTFail() }
        XCTAssertEqual(chainDoc, self.doc(updated: "2025-01-02T00:00:00.000Z"))
        let saved2 = try await store.get("did:swtc:aaa")
        XCTAssertEqual(saved2?.doc, chainDoc)
    }

    func testResolveAndSaveChainOlderKeepsLocal() async throws {
        try await self.saveLocal("did:swtc:bbb", doc: self.doc(updated: "2025-01-02T00:00:00.000Z"), updatedAt: 2)
        self.resolver.setResult(self.doc(updated: "2025-01-01T00:00:00.000Z"))
        let outcome = await core.resolveAndSaveDid("did:swtc:bbb")
        guard case let .document(kept) = outcome else { return XCTFail() }
        XCTAssertEqual(kept, self.doc(updated: "2025-01-02T00:00:00.000Z"), "链上旧于本地 → 保留本地")
    }

    func testUpdatedComparisonHandlesFractionalPrecision() async throws {
        // Swift 修正：Date 比较（Kotlin 字符串比较 0.12Z > 0.1Z 判错）
        try await self.saveLocal("did:swtc:ccc", doc: self.doc(updated: "2025-01-01T00:00:00.1Z"), updatedAt: 1)
        self.resolver.setResult(self.doc(updated: "2025-01-01T00:00:00.12Z"))
        let outcome = await core.resolveAndSaveDid("did:swtc:ccc")
        guard case let .document(chainDoc) = outcome else { return XCTFail() }
        XCTAssertEqual(chainDoc, self.doc(updated: "2025-01-01T00:00:00.12Z"), "120ms 晚于 100ms，链上应胜出")
    }

    func testResolverErrorReturnsErrorOutcome() async throws {
        try await self.saveLocal("did:swtc:ddd", doc: self.doc(updated: "2025-01-01T00:00:00.000Z"), updatedAt: 1)
        self.resolver.setError(TestError.network)
        let outcome = await core.resolveAndSaveDid("did:swtc:ddd")
        guard case .error = outcome else { return XCTFail("桥错误不得伪装成 missing，实际 \(outcome)") }
    }

    // MARK: - missing 分支

    func testMissingChainDeletesLocal() async throws {
        try await self.saveLocal("did:swtc:eee", doc: self.doc(updated: "2025-01-01T00:00:00.000Z"), updatedAt: 1)
        self.resolver.setResult("null")
        let outcome = await core.resolveAndSaveDid("did:swtc:eee")
        guard case .missing = outcome else { return XCTFail() }
        let missing = try await store.get("did:swtc:eee")
        XCTAssertNil(missing)
    }

    func testMissingChainKeepsLocalWhenCreatePending() async throws {
        try await self.saveLocal("did:swtc:fff", doc: self.doc(updated: "2025-01-01T00:00:00.000Z"), updatedAt: 1)
        try await self.store.savePending(DidPending(kind: DidCoreService.pendingCreate, did: "did:swtc:fff", value: nil, updatedAt: 1))
        self.resolver.setResult("{}")
        let outcome = await core.resolveAndSaveDid("did:swtc:fff")
        guard case let .document(kept) = outcome else { return XCTFail() }
        XCTAssertEqual(kept, self.doc(updated: "2025-01-01T00:00:00.000Z"), "create pending 命中 → 保留本地")
        let createPending = try await store.loadPending(kind: DidCoreService.pendingCreate, did: "did:swtc:fff")
        XCTAssertNil(createPending, "命中后清表")
    }

    // MARK: - 删除防复活（Swift 修正，Kotlin 死代码陷阱）

    func testDeletedDidNotResurrectedWhenChainServesOldDoc() async throws {
        // 已删除：本地无文档，pendingDelete 记录了删除时的 updated
        try await self.store.savePending(DidPending(kind: DidCoreService.pendingDelete, did: "did:swtc:ggg", value: "2025-01-01T00:00:00.000Z", updatedAt: 1))
        self.resolver.setResult(self.doc(updated: "2025-01-01T00:00:00.000Z")) // 链上仍服务旧文档（IPFS 延迟）
        let outcome = await core.resolveAndSaveDid("did:swtc:ggg")
        guard case .missing = outcome else { return XCTFail("删除窗口内不得被旧文档复活，实际 \(outcome)") }
        let resurrected = try await store.get("did:swtc:ggg")
        XCTAssertNil(resurrected)
        let deletePending = try await store.loadPending(kind: DidCoreService.pendingDelete, did: "did:swtc:ggg")
        XCTAssertNil(deletePending, "确认后清表")
    }

    func testMissingChainClearsDeletePending() async throws {
        try await self.store.savePending(DidPending(kind: DidCoreService.pendingDelete, did: "did:swtc:hhh", value: "t", updatedAt: 1))
        self.resolver.setResult("null") // tombstone 已传播
        let outcome = await core.resolveAndSaveDid("did:swtc:hhh")
        guard case .missing = outcome else { return XCTFail() }
        let deletePending2 = try await store.loadPending(kind: DidCoreService.pendingDelete, did: "did:swtc:hhh")
        XCTAssertNil(deletePending2)
    }

    // MARK: - avatar / nickname pending 保护

    func testAvatarPendingProtectsLocalUntilChainCatchesUp() async throws {
        let localDoc = #"{"updated":"2025-01-02T00:00:00.000Z","service":[{"type":"Profile","serviceEndpoint":{"preferredAvatar":"avatar-2"}}]}"#
        try await saveLocal("did:swtc:iii", doc: localDoc, updatedAt: 1)
        try await store.savePending(DidPending(kind: DidCoreService.pendingAvatar, did: "did:swtc:iii", value: "avatar-2", updatedAt: 1))
        self.resolver.setResult(#"{"updated":"2025-01-02T00:00:00.000Z","service":[{"type":"Profile","serviceEndpoint":{"preferredAvatar":"avatar-1"}}]}"#)
        let outcome = await core.resolveAndSaveDid("did:swtc:iii")
        guard case let .document(kept) = outcome else { return XCTFail() }
        XCTAssertEqual(kept, localDoc, "链上头像是旧值 → 保护本地新头像")
        let avatarPending = try await store.loadPending(kind: DidCoreService.pendingAvatar, did: "did:swtc:iii")
        XCTAssertNotNil(avatarPending, "pending 保留")
    }

    func testAvatarPendingClearedWhenChainCatchesUp() async throws {
        try await self.saveLocal("did:swtc:jjj", doc: #"{"updated":"2025-01-02T00:00:00.000Z","service":[{"type":"Profile","serviceEndpoint":{"preferredAvatar":"avatar-2"}}]}"#, updatedAt: 1)
        try await self.store.savePending(DidPending(kind: DidCoreService.pendingAvatar, did: "did:swtc:jjj", value: "avatar-2", updatedAt: 1))
        self.resolver.setResult(#"{"updated":"2025-01-02T00:00:00.000Z","service":[{"type":"Profile","serviceEndpoint":{"preferredAvatar":"avatar-2"}}]}"#)
        let outcome = await core.resolveAndSaveDid("did:swtc:jjj")
        guard case .document = outcome else { return XCTFail() }
        let avatarPending2 = try await store.loadPending(kind: DidCoreService.pendingAvatar, did: "did:swtc:jjj")
        XCTAssertNil(avatarPending2, "链上已到位 → 清表")
    }

    func testNicknamePendingProtectsLocal() async throws {
        let localDoc = #"{"updated":"2025-01-02T00:00:00.000Z","service":[{"type":"Profile","serviceEndpoint":{"nickname":"new-name"}}]}"#
        try await saveLocal("did:swtc:kkk", doc: localDoc, updatedAt: 1)
        try await store.savePending(DidPending(kind: DidCoreService.pendingNickname, did: "did:swtc:kkk", value: "new-name", updatedAt: 1))
        self.resolver.setResult(#"{"updated":"2025-01-02T00:00:00.000Z","service":[{"type":"Profile","serviceEndpoint":{"nickname":"old-name"}}]}"#)
        let outcome = await core.resolveAndSaveDid("did:swtc:kkk")
        guard case let .document(kept) = outcome else { return XCTFail() }
        XCTAssertEqual(kept, localDoc)
    }
}

private enum TestError: Error {
    case network
}

/// Fake 链上解析器（自由线程协议）。
final class FakeDidResolver: DidResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var result = "null"
    private var error: Error?

    func setResult(_ result: String) {
        self.lock.withLock {
            self.result = result
            self.error = nil
        }
    }

    func setError(_ error: Error) {
        self.lock.withLock { self.error = error }
    }

    func resolve(_: String) async throws -> String {
        try self.lock.withLock {
            if let error {
                throw error
            }
            return self.result
        }
    }
}
