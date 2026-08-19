import GRDB
@testable import SwiftDid
import XCTest

final class GRDBDidStoreTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBDidStore!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("did-test-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBDidStore(database: self.database)
    }

    override func tearDown() {
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        self.database = nil
        self.store = nil
    }

    private func entity(_ did: String, doc: String, updatedAt: Int64) -> DidEntity {
        DidEntity(did: did, doc: doc, updatedAt: updatedAt)
    }

    // MARK: did_documents

    func testSaveGetDelete() async throws {
        try await self.store.save(self.entity("did:swtc:aaa", doc: #"{"updated":"2025-01-01T00:00:00Z"}"#, updatedAt: 1))
        let loaded = try await store.get("did:swtc:aaa")
        XCTAssertEqual(loaded?.doc, #"{"updated":"2025-01-01T00:00:00Z"}"#)

        try await self.store.delete("did:swtc:aaa")
        let loaded2 = try await store.get("did:swtc:aaa")
        XCTAssertNil(loaded2)
    }

    func testUpsertByDidKeepsLatestDoc() async throws {
        try await self.store.save(self.entity("did:ethr:0xaaa", doc: #"{"updated":"2025-01-01T00:00:00Z"}"#, updatedAt: 1))
        try await self.store.save(self.entity("did:ethr:0xaaa", doc: #"{"updated":"2025-01-02T00:00:00Z"}"#, updatedAt: 2))
        let loaded = try await store.get("did:ethr:0xaaa")
        XCTAssertEqual(loaded?.doc, #"{"updated":"2025-01-02T00:00:00Z"}"#)
        XCTAssertEqual(loaded?.updatedAt, 2)
    }

    func testObserveEmitsSnapshot() async throws {
        try await self.store.save(self.entity("did:swtc:bbb", doc: #"{}"#, updatedAt: 1))
        let all = try await store.observeAll().first(where: { _ in true })
        XCTAssertEqual(all?.first?.did, "did:swtc:bbb")
    }

    // MARK: did_pending

    func testPendingSaveDoesNotRefreshUpdatedAt() async throws {
        try await self.store.savePending(DidPending(kind: "avatar", did: "did:swtc:ccc", value: "avatar-1", updatedAt: 100))
        try await self.store.savePending(DidPending(kind: "avatar", did: "did:swtc:ccc", value: "avatar-2", updatedAt: 200))
        let rows = try await store.loadPending(kind: "avatar", did: "did:swtc:ccc")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.value, "avatar-2", "同 (kind,did) 只保留一条，value 更新")
        XCTAssertEqual(rows.first?.updatedAt, 100, "updatedAt 以首次写入为基准、不续期（TTL 语义）")
    }

    func testPendingDeleteAndExpiredCleanup() async throws {
        try await self.store.savePending(DidPending(kind: "create", did: "did:swtc:ddd", value: nil, updatedAt: 100))
        try await self.store.savePending(DidPending(kind: "delete", did: "did:swtc:ddd", value: "t", updatedAt: 100))
        try await self.store.deletePending(kind: "create", did: "did:swtc:ddd")
        let createRows = try await store.loadPending(kind: "create", did: "did:swtc:ddd")
        XCTAssertEqual(createRows.count, 0)

        try await self.store.deleteExpiredPending(now: 200, ttlMillis: 50) // 100 < 150 → 过期
        let deleteRows = try await store.loadPending(kind: "delete", did: "did:swtc:ddd")
        XCTAssertEqual(deleteRows.count, 0)
    }
}
