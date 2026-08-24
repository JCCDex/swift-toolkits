import GRDB
@testable import SwiftAccount
import SwiftCore
import SwiftVault
import SwiftWallet
import XCTest

/// 门面委托测试（对齐 Kotlin `AccountSdkTest`）：`SwiftAccount` 全方法透传 store、
/// 观察流、`accountManager` 工厂。
final class SwiftAccountFacadeTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBAccountStore!
    private var databaseURL: URL!
    private var account: SwiftAccount!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("facade-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBAccountStore(database: self.database)
        self.account = SwiftAccount(
            store: self.store,
            vault: VaultRepository(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("facade-vault-\(UUID().uuidString).pb")),
            wallet: FakeWalletDeriving()
        )
    }

    override func tearDown() {
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        self.database = nil
        self.store = nil
        self.account = nil
    }

    private func makeAccount(address: String = "0xabc") -> WalletAccount {
        WalletAccount(id: "\(address)#\(ChainType.eth.bip44Code)", address: address, chain: .eth, name: "n", isHD: false, publicKey: "pub")
    }

    func testAccountManagerMember() async {
        // 非可选成员变量：类型即保证存在（对齐 orchestrator_returnsAccountOrchestrator）；
        // 用一个编排方法验证可调用
        let result = await self.account.accountManager.importSubAccount(
            derived: DerivedSubAccount(address: "0xc", chain: .eth, path: Path(chain: ChainType.eth.bip44Code), rootAccountId: "missing", keypair: Keypair(privateKey: "pk", publicKey: "p")),
            name: "c"
        )
        XCTAssertEqual(result, .failure(.rootAccountNotFound), "accountManager 成员可调用")
    }

    func testDelegatesStoreOperations() async throws {
        let account = self.makeAccount()
        try await self.account.addAccount(account)
        let found = try await self.account.findById(account.id)
        XCTAssertEqual(found, account)
        let byAddress = try await self.account.findByAddress("0XABC", chain: .eth)
        XCTAssertEqual(byAddress, account)

        try await self.account.addAccounts([self.makeAccount(address: "0xb")])
        let sameCount = try await self.account.getSameAccountsCount(address: "0xabc")
        XCTAssertEqual(sameCount, 1)

        try await self.account.setCurrentAccount(accountId: account.id)
        let currentId = try await self.account.getCurrentAccountId()
        XCTAssertEqual(currentId, account.id)

        try await self.account.updateAccountName(accountId: account.id, name: "renamed")
        let renamed = try await self.account.findById(account.id)?.name
        XCTAssertEqual(renamed, "renamed")

        try await self.account.removeAccountMeta(accountId: account.id)
        let afterRemove = try await self.account.findById(account.id)
        XCTAssertNil(afterRemove)
    }

    func testObservationStreamsDelegate() async throws {
        let root = WalletAccount(id: "root", address: "root", chain: .swtc, name: "root", isHD: true, path: Path(chain: 0))
        try await self.account.addAccount(root)
        let roots = try await self.firstValue(self.account.rootHDAccounts) ?? []
        XCTAssertEqual(roots.map(\.id), [root.id])
        let all = try await self.firstValue(self.account.accounts) ?? []
        XCTAssertEqual(all.count, 1)
        // accounts(chain:) 是同步方法（返回 AsyncStream），await 作用于 firstValue
        let swtcFirst = try await self.firstValue(self.account.accounts(chain: .swtc)) ?? []
        XCTAssertEqual(swtcFirst.count, 1)
    }

    private func firstValue<T>(_ stream: AsyncStream<T>) async throws -> T? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
