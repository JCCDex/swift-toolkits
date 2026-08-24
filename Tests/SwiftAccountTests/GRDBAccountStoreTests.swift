import GRDB
@testable import SwiftAccount
import SwiftCore
import XCTest

/// GRDBAccountStore 测试（临时文件 DatabasePool；对齐 Account-Swift 04 §3 Store 层）。
final class GRDBAccountStoreTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBAccountStore!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("account-test-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBAccountStore(database: self.database)
    }

    override func tearDown() {
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        self.database = nil
        self.store = nil
    }

    private func makeAccount(
        address: String = "0xabc",
        chain: ChainType = .eth,
        isHD: Bool = false,
        parentId: String? = nil,
        index: Int? = nil
    ) -> WalletAccount {
        WalletAccount(
            id: "\(address)#\(chain.bip44Code)",
            address: address,
            chain: chain,
            name: "n",
            isHD: isHD,
            parentId: parentId,
            path: index.map { Path(chain: chain.bip44Code, index: $0) },
            publicKey: "pub"
        )
    }

    // MARK: - 写 / 查

    func testAddFindRemove() async throws {
        let account = self.makeAccount()
        try await self.store.addAccount(account)
        let v0 = try await self.store.findById(account.id)
        XCTAssertEqual(v0, account)
        let v1 = try await self.store.findByAddress("0xABC", chain: .eth)
        XCTAssertEqual(v1, account, "address 大小写不敏感（LOWER）")
        let v2 = try await self.store.sameAccountsCount(address: "0XABC")
        XCTAssertEqual(v2, 1)

        try await self.store.removeAccount(accountId: account.id)
        let v3 = try await self.store.findById(account.id)
        XCTAssertNil(v3)
    }

    func testAddDuplicateIdThrows() async {
        let account = self.makeAccount()
        try? await self.store.addAccount(account)
        do {
            try await self.store.addAccount(account)
            XCTFail("重复 id 应抛错（对齐 Kotlin @Insert ABORT）")
        } catch {
            // 预期
        }
    }

    func testSetCurrentAccountNotFoundThrows() async {
        do {
            try await self.store.setCurrentAccount(accountId: "missing")
            XCTFail("账户不存在应抛错（对齐 Kotlin NoSuchElementException）")
        } catch {
            // 预期
        }
    }

    func testSetCurrentAndRemoveClearsRow() async throws {
        let account = self.makeAccount()
        try await self.store.addAccount(account)
        try await self.store.setCurrentAccount(accountId: account.id)
        let v4 = try await self.store.currentAccountId()
        XCTAssertEqual(v4, account.id)

        try await self.store.removeAccount(accountId: account.id)
        let v5 = try await self.store.currentAccountId()
        XCTAssertNil(v5, "删除当前账户 → current 行一并删除（clearIfCurrent）")
    }

    func testClearAllClearsCurrent() async throws {
        let account = self.makeAccount()
        try await self.store.addAccount(account)
        try await self.store.setCurrentAccount(accountId: account.id)
        try await self.store.clearAllAccounts()
        let v6 = try await self.store.sameAccountsCount(address: account.address)
        XCTAssertEqual(v6, 0)
        let v7 = try await self.store.currentAccountId()
        XCTAssertNil(v7, "clearAllAccounts 一并清空 current_account")
    }

    func testUpdateNameByAddressCaseInsensitive() async throws {
        let account = self.makeAccount()
        try await self.store.addAccount(account)
        try await self.store.updateAccountNameByAddress(address: "0XABC", name: "renamed")
        let v8 = try await self.store.findById(account.id)?.name
        XCTAssertEqual(v8, "renamed")
    }

    func testGetMaxIndexByChainEmptyReturnsMinusOne() async throws {
        let v9 = try await self.store.maxIndexByChain(parentId: "root", chain: .eth)
        XCTAssertEqual(v9, -1, "空表 MAX 为 NULL → -1")
        let v10 = try await self.store.countSubAccountsByChain(parentId: "root", chain: .eth)
        XCTAssertEqual(v10, 0)
    }

    func testGetMaxIndexByChain() async throws {
        let root = self.makeAccount(address: "root", isHD: true)
        try await self.store.addAccount(root)
        try await self.store.addAccounts([
            self.makeAccount(address: "c0", isHD: true, parentId: root.id, index: 0),
            self.makeAccount(address: "c1", isHD: true, parentId: root.id, index: 1)
        ])
        let maxIndex = try await self.store.maxIndexByChain(parentId: root.id, chain: .eth)
        XCTAssertEqual(maxIndex, 1)
        let subCount = try await self.store.countSubAccountsByChain(parentId: root.id, chain: .eth)
        XCTAssertEqual(subCount, 2)
    }

    // MARK: - 观察流

    func testObserveFilters() async throws {
        let root = self.makeAccount(address: "root", isHD: true)
        let sub = self.makeAccount(address: "sub", isHD: true, parentId: root.id, index: 0)
        let trad = self.makeAccount(address: "trad")
        try await self.store.addAccounts([root, sub, trad])

        let roots = try await self.firstValue(self.store.observeRootHDAccounts()) ?? []
        let subs = try await self.firstValue(self.store.observeSubHDAccounts()) ?? []
        let trads = try await self.firstValue(self.store.observeTraditionalAccounts()) ?? []
        let all = try await self.firstValue(self.store.observeAccounts()) ?? []
        let swtc = try await self.firstValue(self.store.observeAccounts(chain: .swtc)) ?? []
        XCTAssertEqual(roots.map(\.id), [root.id])
        XCTAssertEqual(subs.map(\.id), [sub.id])
        XCTAssertEqual(trads.map(\.id), [trad.id])
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(swtc.count, 0)
    }

    func testObserveCurrentAccountPushesNilWhenEmpty() async throws {
        // firstValue 返回 T?，T = WalletAccount? → 双层可选；拍平后应为 nil
        let first = try await self.firstValue(self.store.observeCurrentAccount())
        XCTAssertNil(first ?? nil, "空库 current 流首帧推 nil")
    }

    /// AsyncStream 取首帧（复用 SwiftNft 惯例）。
    private func firstValue<T>(_ stream: AsyncStream<T>) async throws -> T? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    // MARK: - 对齐 Kotlin RoomAccountStoreTest 的补充用例

    func testAddHdRootAndSub() async throws {
        let root = self.makeAccount(address: "root", isHD: true)
        let sub = self.makeAccount(address: "sub", isHD: true, parentId: root.id, index: 0)
        try await self.store.addAccounts([root, sub])
        let v100 = try await self.store.findById(root.id)?.isHD
        XCTAssertEqual(v100, true)
        let v101 = try await self.store.findByAddress("sub", chain: .eth)?.parentId
        XCTAssertEqual(v101, root.id)
        let v102 = try await self.firstValue(self.store.observeSubAccounts(of: root.id)) ?? []
        XCTAssertEqual(v102.count, 1)
    }

    func testRemovePreservesCurrentWhenDeletingOther() async throws {
        let a = self.makeAccount(address: "0xa")
        let b = self.makeAccount(address: "0xb")
        try await self.store.addAccounts([a, b])
        try await self.store.setCurrentAccount(accountId: a.id)
        try await self.store.removeAccount(accountId: b.id)
        let v102 = try await self.store.currentAccountId()
        XCTAssertEqual(v102, a.id, "删除非当前账户保留 current")
    }

    func testUpdateNameAndPublicKeyAndParentId() async throws {
        let account = self.makeAccount()
        try await self.store.addAccount(account)
        try await self.store.updateAccountName(accountId: account.id, name: "renamed")
        try await self.store.updatePublicKey(accountId: account.id, publicKey: "new-pub")
        try await self.store.updateParentId(account.id, parentId: "root")
        let updated = try await self.store.findById(account.id)
        XCTAssertEqual(updated?.name, "renamed")
        XCTAssertEqual(updated?.publicKey, "new-pub")
        XCTAssertEqual(updated?.parentId, "root")
    }

    func testSetCurrentAccountFlowEmitsAccount() async throws {
        let account = self.makeAccount()
        try await self.store.addAccount(account)
        try await self.store.setCurrentAccount(accountId: account.id)
        let current = try await self.firstValue(self.store.observeCurrentAccount())
        XCTAssertEqual(current ?? nil, account, "设置 current 后流推该账户")
    }

    func testCurrentAccountNilWhenPointsToMissing() async throws {
        // 直接删 accounts 行（不清 current）→ current 指向缺失账户 → 流推 nil
        let account = self.makeAccount()
        try await self.store.addAccount(account)
        try await self.store.setCurrentAccount(accountId: account.id)
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [account.id])
        }
        let current = try await self.firstValue(self.store.observeCurrentAccount())
        XCTAssertNil(current ?? nil, "current 指向缺失账户 → 流推 nil")
    }

    func testFindNonRootAccountFiltersTraditionalAndHdSub() async throws {
        // 注意：id 是 PK（冲突即抛），且同地址同链会撞 findNonRootAccount 判重键——测试数据须跨地址/跨链
        let trad = self.makeAccount(address: "0xshared")
        let root = self.makeAccount(address: "root", isHD: true)
        let sub = self.makeAccount(address: "0xsub", isHD: true, parentId: root.id, index: 0)
        try await self.store.addAccounts([trad, root, sub])
        // 传统账户（isHD=0）→ findNonRootAccount 命中
        let v103 = try await self.store.findNonRootAccount(address: "0XSHARED", chain: .eth)
        XCTAssertNotNil(v103)
        // HD 子账户 → 命中
        let v104 = try await self.store.findNonRootAccount(address: "0xsub", chain: .eth)
        XCTAssertEqual(v104?.parentId, root.id)
        // HD 根（isHD=1, parentId null）不命中
        let v105 = try await self.store.findNonRootAccount(address: "root", chain: .eth)
        XCTAssertNil(v105)
    }
}
