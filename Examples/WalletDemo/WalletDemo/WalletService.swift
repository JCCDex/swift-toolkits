import Foundation
import GRDB
import os
import SwiftAccount
import SwiftCore
import SwiftDappConnect
import SwiftVault
import SwiftWallet

/// 钱包服务：组合模块——
/// - SwiftWallet：隐藏 WebView 里的 jcc-wallet 加密库门面（生成助记词/派生账户）
/// - SwiftVault：密码加密持久化私钥/助记词
/// - **SwiftAccount：账户元数据列表/当前选中（GRDB `accounts` + `current_account` 表）**
/// - SwiftCore：共享模型（WalletAccount/ChainType/Path）
@MainActor
final class WalletService: ObservableObject {
    private let log = Logger(subsystem: "com.swifttoolkits.WalletDemo", category: "wallet")
    @Published var status = ""
    @Published var isLoading = false

    /// 地址列表 + 当前地址（DApp 的 eth_requestAccounts 读取；由 SwiftAccount 观察流驱动）
    let state = DemoWalletState()

    /// demo 固定密码（仅示例；真实 App 应引导用户设置并放入 Keychain）
    private let demoPassword = Data("demo-password-1234".utf8)

    private let vault: VaultRepository
    private let wallet: SwiftWallet

    /// 账户门面（列表/当前选中/查询）+ 编排器（导入等操作）——列表与操作均走 Account API
    let account: SwiftAccount
    let accountManager: AccountManager

    init() {
        let baseURL =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        let dir = baseURL.appendingPathComponent("WalletDemo", isDirectory: true)
        // 卸载后首次启动目录不存在：GRDB 不会自动建父目录，必须先创建（环境错误 demo 用 try!）
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 本地 DB 创建失败属环境错误（demo 用 try!）
        let store = try! GRDBAccountStore(
            database: try! DatabasePool(path: dir.appendingPathComponent("account.sqlite").path)
        )
        self.vault = VaultRepository(storageURL: dir.appendingPathComponent("vault.pb", isDirectory: false))
        self.wallet = SwiftWallet()
        self.account = SwiftAccount(store: store, vault: self.vault, wallet: self.wallet)
        self.accountManager = self.account.accountManager
        // 观察流驱动列表/当前地址（首帧即当前值；current_account 表持久化，重启自动恢复）
        self.state.bind(account: self.account)
    }

    // MARK: - 启动（加载本地账户：观察流自动填充，此处仅启动桥）

    func loadExistingWallets() async throws {
        guard try await self.vault.hasPassword() else {
            self.status = ""
            return
        }
        // 列表/当前地址由 state.bind 的观察流自动推送（含重启恢复 current_account）
        self.status = "已加载 \(self.state.accounts.count) 个钱包"
    }

    // MARK: - 生成/新增钱包（助记词 → 派生 ETH 账户 → 导入 SwiftVault）

    func addWallet() async throws {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        self.status = "正在启动加密桥…"
        try self.wallet.start()

        self.status = "正在生成助记词…"
        let mnemonic = try await self.wallet.generateMnemonic()

        self.status = "正在派生 ETH 账户…"
        let derived = try await self.wallet.deriveFromMnemonic(
            mnemonic: mnemonic.value,
            chain: ChainType.eth.bip44Code
        )

        self.status = "正在导入账户…"
        // vault 解锁/初始化（AccountManager.importSingleAccount 内部把助记词+私钥落 vault）
        if try await !self.vault.hasPassword() {
            _ = try await self.vault.initializePassword(self.demoPassword)
        } else {
            _ = try await self.vault.unlock(self.demoPassword) // vault.pb 已存在：新进程先解锁
        }
        let result = await self.accountManager.importSingleAccount(
            derived: TraditionalDeriveResult(
                address: derived.address,
                keypair: derived.keypair,
                mnemonic: mnemonic,
                path: derived.path
            ),
            chain: .eth,
            name: "Demo Wallet",
            isHD: false,
            parentId: nil
        )
        guard case let .success(accountId) = result else {
            self.status = "导入失败：\(result)"
            return
        }
        // 新钱包设为当前地址（Account API）
        try? await self.account.setCurrentAccount(accountId: accountId)
        self.status = "钱包已生成：\(derived.address)"
    }

    // MARK: - 生成 HD 钱包（根 + 子账户；演示 importHdWallet）

    /// 生成 HD 钱包：根账户（SWTC）+ 指定链的子账户（走 `importHdWallet`，私钥在导入时
    /// 全部落 vault）。返回 rootAccountId 供后续 `deriveAndImportSubAccount` 派生子账户。
    func addHDWallet() async throws -> String? {
        guard !self.isLoading else { return nil }
        self.isLoading = true
        defer { self.isLoading = false }
        self.status = "正在启动加密桥…"
        try self.wallet.start()

        self.status = "正在生成助记词…"
        let mnemonic = try await self.wallet.generateMnemonic()
        // chains: [eth, swtc] → HD 子账户（BIP44 同路径多链）
        let hd = try await self.wallet.hdWalletFromMnemonic(
            mnemonic: mnemonic.value,
            chains: [ChainType.eth.bip44Code, ChainType.swtc.bip44Code],
            language: mnemonic.language
        )

        self.status = "正在导入 HD 钱包…"
        if try await !self.vault.hasPassword() {
            _ = try await self.vault.initializePassword(self.demoPassword)
        } else {
            _ = try await self.vault.unlock(self.demoPassword)
        }
        let result = await self.accountManager.importHdWallet(
            hdResult: hd,
            name: "HD Wallet",
            password: self.demoPassword
        )
        guard case let .success(imported) = result else {
            self.status = "HD 导入失败：\(result)"
            return nil
        }
        self.status = "HD 钱包已生成：根 \(hd.address) + \(imported.children.count) 个子账户"
        return imported.rootAccountId
    }

    // MARK: - 派生子账户（两步：deriveSubAccount 只派生 → importSubAccount 落库）

    /// 从 HD 根账户派生子账户并落库。
    /// ⚠️ 新语义（review SwiftAccount P1#1）：`deriveSubAccount` **只派生不落 vault**（返回
    /// 完整 keypair），私钥由 `importSubAccount` 显式落库——两步缺一不可，否则子账户
    /// 元数据在但密钥不在 vault，无法签名。
    /// - Parameters:
    ///   - rootAccountId: HD 根账户 id（`accountManager.importHdWallet` 返回的 rootAccountId）。
    ///   - chain: 子账户链（如 `.eth`）。
    ///   - index: 指定派生 index；nil = 自动取 `maxIndex+1`。
    func deriveAndImportSubAccount(
        rootAccountId: String,
        chain: ChainType,
        index: Int? = nil
    ) async -> String? {
        // 1) 派生（只派生，不落库）
        let derived = await self.accountManager.deriveSubAccount(
            chain: chain,
            rootAccountId: rootAccountId,
            password: self.demoPassword,
            index: index
        )
        guard case let .success(subAccount) = derived else {
            self.status = "派生子账户失败：\(derived)"
            return nil
        }
        // 2) 落库（这里才把子账户私钥写入 vault + 元数据写入 store）
        let imported = await self.accountManager.importSubAccount(
            derived: subAccount,
            name: "\(chain.label)-HD"
        )
        guard case let .success(accountId) = imported else {
            self.status = "导入子账户失败：\(imported)"
            return nil
        }
        self.status = "子账户已派生并落库：\(subAccount.address)"
        return accountId
    }

    // MARK: - 按地址查看密钥（从 SwiftVault 解密读出）

    /// 查看地址的私钥 + 助记词。HD 子账户的助记词存在**根账户**地址下（importHdWallet
    /// 以根地址存 mnemonic），子账户地址只有私钥——故需传 `mnemonicFrom`（根地址）。
    /// - Parameters:
    ///   - address: 要查看的账户地址（私钥按其查）。
    ///   - mnemonicFrom: 助记词归属地址；nil = 与 `address` 相同（传统账户）。
    func revealKey(
        for address: String,
        mnemonicFrom rootAddress: String? = nil
    ) async throws -> (privateKey: String, mnemonic: String) {
        let privateKey = try await self.vault.getPrivateKey(address: address, password: self.demoPassword)
        let mnemonicAddress = rootAddress ?? address
        let mnemonic = try await self.vault.getMnemonic(address: mnemonicAddress, password: self.demoPassword)
        return (
            String(decoding: privateKey, as: UTF8.self),
            String(decoding: mnemonic, as: UTF8.self)
        )
    }

    // MARK: - 供 DApp 签名流取钥（DemoSecretProvider 委托）

    /// 返回地址对应的私钥（SwiftVault 解密；未解锁自动解锁），无则 nil。
    /// DApp 侧 eth_signTransaction 等签名请求经中间件 → SecretProvider 走到这里。
    func privateKey(for address: String) async -> String? {
        guard
            let data = try? await self.vault.getPrivateKey(address: address, password: self.demoPassword)
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// SWTC secret（demo 与私钥同源存储）。
    func secret(for address: String) async -> String? {
        await self.privateKey(for: address)
    }
}
