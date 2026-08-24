import GRDB
@testable import SwiftAccount
import SwiftCore
import SwiftVault
import SwiftWallet
import XCTest

/// AccountManager 测试：GRDBAccountStore（临时库）+ 真实 VaultRepository（临时存储）+
/// FakeWalletDeriving（派生返回固定结果；对齐 Account-Swift 04 §3 编排器层）。
final class AccountManagerTests: XCTestCase {
    private var database: DatabasePool!
    private var store: GRDBAccountStore!
    private var databaseURL: URL!
    private var vaultURL: URL!
    private var vault: VaultRepository!
    private var wallet: FakeWalletDeriving!
    private var manager: AccountManager!

    override func setUpWithError() throws {
        self.databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("orch-test-\(UUID().uuidString).sqlite")
        self.database = try DatabasePool(path: self.databaseURL.path)
        self.store = try GRDBAccountStore(database: self.database)
        self.vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent("orch-vault-\(UUID().uuidString).pb")
        self.vault = VaultRepository(storageURL: self.vaultURL)
        self.wallet = FakeWalletDeriving()
        self.manager = AccountManager(store: self.store, vault: self.vault, wallet: self.wallet)
    }

    override func tearDown() {
        try? self.database.close()
        try? FileManager.default.removeItem(at: self.databaseURL)
        try? FileManager.default.removeItem(at: self.vaultURL)
        self.database = nil
        self.store = nil
        self.vault = nil
        self.wallet = nil
        self.manager = nil
    }

    private let password = Data("test-password".utf8)

    private func keypair(_ address: String) -> Keypair {
        Keypair(privateKey: "pk-\(address)", publicKey: "pub-\(address)")
    }

    // MARK: - importSingleAccount

    func testImportSingleAccountSuccessAndDuplicate() async throws {
        // persistVaultMaterial 的 importPrivateKey 需 vault 已解锁（requireSessionKey）——先初始化密码
        try await self.vault.initializePassword(self.password)
        let derived = TraditionalDeriveResult(address: "0xabc", keypair: self.keypair("0xabc"), path: nil)
        let result = await self.manager.importSingleAccount(
            derived: derived, chain: .eth, name: "acc", isHD: false, parentId: nil
        )
        guard case let .success(id) = result else {
            return XCTFail("应成功，得到 \(result)")
        }
        // id 为默认 UUID（对齐 Kotlin：判重依赖入口 findNonRootAccount 的 address 预检，与 id 无关）
        let saved = try await self.store.findById(id)
        XCTAssertNotNil(saved, "导入的账户应能按返回 id 查回")
        XCTAssertEqual(saved?.address, "0xabc")

        let dup = await self.manager.importSingleAccount(
            derived: derived, chain: .eth, name: "acc", isHD: false, parentId: nil
        )
        XCTAssertEqual(dup, .failure(.addressAlreadyExists))
        // 密钥已落 vault
        let inKeys = try await self.vault.addressInKeys("0xabc")
        XCTAssertTrue(inKeys)
    }

    // MARK: - P0-5：vault 落库失败必须向上抛（不得「账户成功但私钥未入库」）

    func testImportSingleAccountFailsWhenVaultLocked() async throws {
        // vault 未初始化密码 → requireSessionKey 抛 vaultLocked；persistVault 不得用 try? 吞掉
        let derived = TraditionalDeriveResult(address: "0xabc", keypair: self.keypair("0xabc"), path: nil)
        let result = await self.manager.importSingleAccount(
            derived: derived, chain: .eth, name: "acc", isHD: false, parentId: nil
        )
        XCTAssertEqual(result, .failure(.failure("vaultLocked")), "vault 锁定 → 应返回 failure 而非 success")
        let saved = try await self.store.findByAddress("0xabc")
        XCTAssertNil(saved, "vault 落库失败时不得写入账户元数据（P0-5 回归：曾报成功但私钥未入库）")
    }

    func testImportSingleAccountMnemonicBranchFailsWhenVaultLocked() async throws {
        let mnemonic = Mnemonic(
            value: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            language: "english"
        )
        let derived = TraditionalDeriveResult(address: "0xabc", keypair: self.keypair("0xabc"), mnemonic: mnemonic, path: nil)
        let result = await self.manager.importSingleAccount(
            derived: derived, chain: .eth, name: "acc", isHD: false, parentId: nil
        )
        XCTAssertEqual(result, .failure(.failure("vaultLocked")), "mnemonic 分支同样向上抛，不得吞错")
        let saved = try await self.store.findByAddress("0xabc")
        XCTAssertNil(saved)
    }

    func testImportSingleAccountSecretBranchFailsWhenVaultLocked() async throws {
        let derived = TraditionalDeriveResult(address: "0xabc", keypair: self.keypair("0xabc"), secret: "s3cr3t", path: nil)
        let result = await self.manager.importSingleAccount(
            derived: derived, chain: .eth, name: "acc", isHD: false, parentId: nil
        )
        XCTAssertEqual(result, .failure(.failure("vaultLocked")), "secret 分支同样向上抛，不得吞错")
        let saved = try await self.store.findByAddress("0xabc")
        XCTAssertNil(saved)
    }

    // MARK: - importHdWallet

    func testImportHdWalletRootAndChildren() async throws {
        let hd = GenerateHDWalletResult(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            address: "rootAddr",
            language: "english",
            keypair: self.keypair("rootAddr"),
            accounts: [
                SubWallet(chain: ChainType.eth.bip44Code, address: "0xeth", path: Path(chain: ChainType.eth.bip44Code, index: 0), keypair: self.keypair("0xeth")),
                SubWallet(chain: ChainType.swtc.bip44Code, address: "jswtc", path: Path(chain: ChainType.swtc.bip44Code, index: 0), keypair: self.keypair("jswtc")),
                SubWallet(chain: 999_999, address: "unknown-chain", path: Path(chain: 999_999), keypair: self.keypair("unknown-chain"))
            ]
        )
        let result = await self.manager.importHdWallet(hdResult: hd, name: "My HD", password: self.password)

        guard case let .success(imported) = result else {
            return XCTFail("应成功，得到 \(result)")
        }
        // 根 + 2 个已知链子账户；未知链整体跳过
        let rootCount = try await self.store.getSameAccountsCount(address: "rootAddr")
        XCTAssertEqual(rootCount, 1)
        XCTAssertEqual(imported.children.count, 2)
        XCTAssertEqual(imported.children[0].chain, .eth)
        XCTAssertEqual(imported.children[1].chain, .swtc)
        let unknown = try await self.store.findByAddress("unknown-chain")
        XCTAssertNil(unknown)
        let ethName = try await self.store.findByAddress("0xeth")?.name
        XCTAssertEqual(ethName, "Ethereum-HD", "ChainType.label 命名")
        // vault：根 mnemonic + 子私钥已导入
        let hasMnemonic = try await self.vault.addressInMnemonics("rootAddr")
        let hasEth = try await self.vault.addressInKeys("0xeth")
        let hasSwtc = try await self.vault.addressInKeys("jswtc")
        XCTAssertTrue(hasMnemonic)
        XCTAssertTrue(hasEth)
        XCTAssertTrue(hasSwtc)
    }

    func testImportHdWalletPasswordRequiredWhenVaultEmpty() async {
        let hd = GenerateHDWalletResult(
            mnemonic: "m", address: "rootAddr", language: "english",
            keypair: self.keypair("rootAddr"), accounts: []
        )
        let result = await self.manager.importHdWallet(hdResult: hd, name: "x", password: nil)
        XCTAssertEqual(result, .failure(.passwordRequired))
    }

    // 清空操作已从 importHdWallet 解耦（用户要求）：clearExisting/clearExistingPassword
    // 参数移除，清库统一走 clearWalletData（密码门测试见 testClearWalletData）。

    // MARK: - deriveSubAccount

    func testDeriveSubAccountIndexProgressionAndMutex() async throws {
        // 先导入根（vault 有 mnemonic）
        try await self.vault.initializePassword(self.password)
        let hd = GenerateHDWalletResult(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            address: "rootAddr", language: "english",
            keypair: self.keypair("rootAddr"), accounts: []
        )
        guard case let .success(imported) = await self.manager.importHdWallet(hdResult: hd, name: "Root", password: self.password) else {
            return XCTFail("导入根失败")
        }
        // Fake：派生地址 = "0xchild-<index>"，索引推进
        self.wallet.setDeriveAddresses { _, index in
            "0xchild-\(index)"
        }
        let first = await self.manager.deriveSubAccount(chain: .eth, rootAccountId: imported.rootAccountId, password: self.password)
        guard case let .success(derived1) = first else {
            return XCTFail("第一次派生失败：\(first)")
        }
        XCTAssertEqual(derived1.address, "0xchild-0", "空表 getMaxIndexByChain=-1 → 首个子账户 index 0")

        // 落库后自动索引推进到 1
        _ = await self.manager.importSubAccount(derived: derived1, name: "c1")
        let second = await self.manager.deriveSubAccount(chain: .eth, rootAccountId: imported.rootAccountId, password: self.password)
        guard case let .success(derived2) = second else {
            return XCTFail("第二次派生失败：\(second)")
        }
        XCTAssertEqual(derived2.address, "0xchild-1", "已有 index 0 → 自动推进到 1")
    }

    func testDeriveSubAccountRootNotFound() async {
        let result = await self.manager.deriveSubAccount(chain: .eth, rootAccountId: "missing", password: self.password)
        XCTAssertEqual(result, .failure(.rootAccountNotFound))
    }

    // MARK: - removeAccount / clearWalletData

    func testRemoveAccountWrongPasswordAndIdempotent() async throws {
        try await self.vault.initializePassword(self.password)
        let wrong = await self.manager.removeAccount(accountId: "any", password: Data("wrong".utf8))
        guard case .failure(.wrongPassword) = wrong else {
            return XCTFail("M-14：密码先校验，得到 \(wrong)")
        }

        let missing = await self.manager.removeAccount(accountId: "missing", password: self.password)
        guard case .success = missing else {
            return XCTFail("账户不存在 → 幂等成功，得到 \(missing)")
        }
    }

    func testClearWalletData() async throws {
        try await self.vault.initializePassword(self.password)
        let derived = TraditionalDeriveResult(address: "0xabc", keypair: self.keypair("0xabc"), path: nil)
        _ = await self.manager.importSingleAccount(derived: derived, chain: .eth, name: "a", isHD: false, parentId: nil)

        let wrong = await self.manager.clearWalletData(password: Data("wrong".utf8))
        guard case .failure(.wrongPassword) = wrong else {
            return XCTFail("错误密码应失败，得到 \(wrong)")
        }

        let ok = await self.manager.clearWalletData(password: self.password)
        guard case .success = ok else {
            return XCTFail("清除应成功，得到 \(ok)")
        }
        let count = try await self.store.getSameAccountsCount(address: "0xabc")
        XCTAssertEqual(count, 0)
    }

    // MARK: - 对齐 Kotlin AccountOrchestratorTest 的补充用例

    func testImportSingleAccountWithMnemonic() async throws {
        try await self.vault.initializePassword(self.password)
        let mnemonic = Mnemonic(value: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", language: "english")
        let derived = TraditionalDeriveResult(address: "0xabc", keypair: self.keypair("0xabc"), mnemonic: mnemonic, path: nil)
        let result = await self.manager.importSingleAccount(derived: derived, chain: .eth, name: "a", isHD: false, parentId: nil)
        guard case .success = result else { return XCTFail("应成功：\(result)") }
        let inMnemonics = try await self.vault.addressInMnemonics("0xabc")
        XCTAssertTrue(inMnemonics, "mnemonic 分支落 vault mnemonics")
    }

    func testImportSingleAccountWithSecret() async throws {
        try await self.vault.initializePassword(self.password)
        let derived = TraditionalDeriveResult(address: "0xabc", keypair: self.keypair("0xabc"), secret: "my-secret", path: nil)
        let result = await self.manager.importSingleAccount(derived: derived, chain: .eth, name: "a", isHD: false, parentId: nil)
        guard case .success = result else { return XCTFail("应成功：\(result)") }
        let inSecrets = try await self.vault.addressInSecrets("0xabc")
        XCTAssertTrue(inSecrets, "secret 分支落 vault secrets")
    }

    func testImportHdWalletInitializesPasswordWhenVaultEmpty() async throws {
        let hd = GenerateHDWalletResult(mnemonic: "m", address: "rootAddr", language: "english", keypair: self.keypair("rootAddr"), accounts: [])
        let result = await self.manager.importHdWallet(hdResult: hd, name: "x", password: self.password)
        guard case .success = result else { return XCTFail("应成功：\(result)") }
        let hasPwd = try await self.vault.hasPassword()
        XCTAssertTrue(hasPwd, "空 vault + password → 初始化密码")
    }

    func testImportHdWalletReturnsErrorWhenRootExists() async throws {
        try await self.vault.initializePassword(self.password)
        let hd = GenerateHDWalletResult(mnemonic: "m", address: "rootAddr", language: "english", keypair: self.keypair("rootAddr"), accounts: [])
        _ = await self.manager.importHdWallet(hdResult: hd, name: "x", password: self.password)
        let dup = await self.manager.importHdWallet(hdResult: hd, name: "y", password: self.password)
        XCTAssertEqual(dup, .failure(.accountAlreadyExists))
    }

    func testImportHdWalletSkipsDuplicateChildren() async throws {
        // 子账户地址已存在（传统账户同地址）→ 导入 HD 时跳过、不覆盖
        try await self.store.addAccount(WalletAccount(
            id: "0xeth#\(ChainType.eth.bip44Code)", address: "0xeth", chain: .eth, name: "pre", isHD: false, publicKey: "p"
        ))
        let hd = GenerateHDWalletResult(
            mnemonic: "m", address: "rootAddr", language: "english", keypair: self.keypair("rootAddr"),
            accounts: [SubWallet(chain: ChainType.eth.bip44Code, address: "0xeth", path: Path(chain: ChainType.eth.bip44Code), keypair: self.keypair("0xeth"))]
        )
        let result = await self.manager.importHdWallet(hdResult: hd, name: "y", password: self.password)
        guard case let .success(imported) = result else { return XCTFail("应成功：\(result)") }
        XCTAssertEqual(imported.children.count, 0, "子账户已存在 → 跳过")
        let existing = try await self.store.findById("0xeth#\(ChainType.eth.bip44Code)")
        XCTAssertEqual(existing?.isHD, false, "原传统账户未被覆盖")
    }

    func testImportSubAccountRootNotFound() async {
        let derived = DerivedSubAccount(address: "0xc", chain: .eth, path: Path(chain: ChainType.eth.bip44Code), rootAccountId: "missing", publicKey: "p")
        let result = await self.manager.importSubAccount(derived: derived, name: "c")
        XCTAssertEqual(result, .failure(.rootAccountNotFound))
    }

    func testRemoveAccountVaultSemantics() async throws {
        try await self.vault.initializePassword(self.password)
        // 同地址两个账户（跨链）：删一个保留 vault；删最后一个清 vault
        guard case let .success(ethId) = await self.manager.importSingleAccount(
            derived: TraditionalDeriveResult(address: "0xshared", keypair: self.keypair("0xshared"), path: nil),
            chain: .eth, name: "e", isHD: false, parentId: nil
        ) else { return XCTFail("导入 eth 账户失败") }
        guard case let .success(swtcId) = await self.manager.importSingleAccount(
            derived: TraditionalDeriveResult(address: "0xshared", keypair: self.keypair("0xshared"), path: nil),
            chain: .swtc, name: "s", isHD: false, parentId: nil
        ) else { return XCTFail("导入 swtc 账户失败") }

        let first = await self.manager.removeAccount(accountId: ethId, password: self.password)
        guard case .success = first else { return XCTFail("删一个应成功：\(first)") }
        let stillInKeys = try await self.vault.addressInKeys("0xshared")
        XCTAssertTrue(stillInKeys, "同地址还有另一账户 → 保留 vault")

        let last = await self.manager.removeAccount(accountId: swtcId, password: self.password)
        guard case .success = last else { return XCTFail("删最后一个应成功：\(last)") }
        let removed = try await self.vault.addressInKeys("0xshared")
        XCTAssertFalse(removed, "同地址最后一条 → 同步删 vault 密钥")
    }

    func testDeriveSubAccountUsesSpecifiedIndex() async throws {
        try await self.vault.initializePassword(self.password)
        let hd = GenerateHDWalletResult(mnemonic: "m", address: "rootAddr", language: "english", keypair: self.keypair("rootAddr"), accounts: [])
        guard case let .success(imported) = await self.manager.importHdWallet(hdResult: hd, name: "Root", password: self.password) else {
            return XCTFail("导入根失败")
        }
        let result = await self.manager.deriveSubAccount(chain: .eth, rootAccountId: imported.rootAccountId, password: self.password, index: 5)
        guard case let .success(derived) = result else { return XCTFail("显式 index 派生失败：\(result)") }
        XCTAssertEqual(derived.path.index, 5, "显式 index=5 不使用自动推进")
    }

    func testDeriveSubAccountReturnsFailureWhenWalletThrows() async throws {
        try await self.vault.initializePassword(self.password)
        let hd = GenerateHDWalletResult(mnemonic: "m", address: "rootAddr", language: "english", keypair: self.keypair("rootAddr"), accounts: [])
        guard case let .success(imported) = await self.manager.importHdWallet(hdResult: hd, name: "Root", password: self.password) else {
            return XCTFail("导入根失败")
        }
        self.wallet.setThrowError(AccountOperationError.failure("sdk error"))
        let result = await self.manager.deriveSubAccount(chain: .eth, rootAccountId: imported.rootAccountId, password: self.password)
        guard case let .failure(.failure(message)) = result else {
            return XCTFail("wallet 抛错 → failure，得到 \(result)")
        }
        XCTAssertTrue(message.contains("sdk error"))
    }
}

/// Fake 派生器：按配置返回地址；记录调用。
final class FakeWalletDeriving: WalletDeriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _deriveAddresses: (@Sendable (Int64, Int) -> String)?
    private var _throwError: Error?

    /// 配置 deriveChild 抛错（对齐 deriveSubAccount_returnsFailureWhenWalletSdkThrows）。
    func setThrowError(_ error: Error?) {
        self.lock.withLock { self._throwError = error }
    }

    private var _calls: [(chain: Int64, index: Int)] = []

    var calls: [(chain: Int64, index: Int)] {
        self.lock.withLock { self._calls }
    }

    /// 配置 deriveChild 的地址生成（chain, index）→ address。
    func setDeriveAddresses(_ closure: @escaping @Sendable (Int64, Int) -> String) {
        self.lock.withLock { self._deriveAddresses = closure }
    }

    func deriveChild(
        mnemonic _: String,
        chain: Int64,
        account: Int,
        change: Int,
        index: Int,
        language _: String
    ) async throws -> SubWallet {
        if let error = self.lock.withLock({ self._throwError }) {
            throw error
        }
        let address = self.lock.withLock { () -> String in
            self._calls.append((chain, index))
            return self._deriveAddresses?(chain, index) ?? "0xchild-\(index)"
        }
        return SubWallet(chain: chain, address: address, path: Path(chain: chain, account: account, change: change, index: index), keypair: Keypair(privateKey: "pk", publicKey: "pub"))
    }

    func hdWalletFromMnemonic(mnemonic: String, chains _: [Int64], language: String) async throws -> GenerateHDWalletResult {
        GenerateHDWalletResult(mnemonic: mnemonic, address: "addr", language: language, keypair: Keypair(privateKey: "pk", publicKey: "pub"), accounts: [])
    }

    func deriveFromPrivateKey(privateKey: String, chain _: Int64) async throws -> TraditionalDeriveResult {
        TraditionalDeriveResult(address: "0xfrom", keypair: Keypair(privateKey: privateKey, publicKey: "pub"), path: nil)
    }
}
