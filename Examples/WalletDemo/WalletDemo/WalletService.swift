import Foundation
import os
import SwiftDappConnect
import SwiftVault
import SwiftWebviewBridge

/// 钱包服务：组合三个模块——
/// - SwiftWebviewBridge：隐藏 WebView 里的 jcc-wallet 加密库（生成助记词/派生账户）
/// - SwiftVault：密码加密持久化私钥/助记词
@MainActor
final class WalletService: ObservableObject {
    private let log = Logger(subsystem: "com.swifttoolkits.WalletDemo", category: "wallet")
    @Published var status = ""
    @Published var isLoading = false

    /// 地址列表 + 当前地址（DApp 的 eth_requestAccounts 读取）
    let state = DemoWalletState()

    /// demo 固定密码（仅示例；真实 App 应引导用户设置并放入 Keychain）
    private let demoPassword = Data("demo-password-1234".utf8)

    private let vault: VaultRepository
    private let engine = WebviewBridgeEngine.shared

    /// ETH BIP44 链码（与 SwiftDappConnect `ChainType.eth.bip44Code` 一致）
    private let chainETH: Int64 = 2_147_483_708

    init() {
        let baseURL =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        self.vault = VaultRepository(
            storageURL: baseURL
                .appendingPathComponent("WalletDemo", isDirectory: true)
                .appendingPathComponent("vault.pb", isDirectory: false)
        )
    }

    // MARK: - 启动加载（本地已生成的钱包）

    func loadExistingWallets() async throws {
        guard try await self.vault.hasPassword() else {
            self.status = ""
            return
        }
        let addresses = try await self.vault.listAccounts()
        self.state.accounts = addresses.map { self.makeAccount(address: $0) }
        // 恢复上次选择的当前地址；地址已不存在（如重装/清空）时回退第一个
        if let saved = DemoWalletState.savedCurrentAddress(),
           self.state.accounts.contains(where: { $0.address.caseInsensitiveCompare(saved) == .orderedSame }) {
            self.state.currentAddress = saved
        } else {
            self.state.currentAddress = self.state.accounts.first?.address
        }
        self.log.notice("currentAddress restored: \(self.state.currentAddress ?? "nil", privacy: .public)")
        self.status = self.state.accounts.isEmpty ? "" : "已加载 \(self.state.accounts.count) 个钱包"
    }

    // MARK: - 生成/新增钱包（助记词 → 派生 ETH 账户 → 导入 SwiftVault）

    func addWallet() async throws {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        self.status = "正在启动加密桥…"
        try await self.startBridgeIfNeeded()

        self.status = "正在生成助记词…"
        let mnemonic: GeneratedMnemonic = try await self.engine.callJsMethodAs(
            method: "generateMnemonic",
            params: ["length": 128, "language": "english"],
            as: GeneratedMnemonic.self
        )

        self.status = "正在派生 ETH 账户…"
        let derived: DerivedChildResult = try await self.engine.callJsMethodAs(
            method: "deriveChild",
            params: [
                "mnemonic": mnemonic.value,
                "chain": self.chainETH,
                "account": 0,
                "change": 0,
                "index": 0,
                "language": mnemonic.language
            ],
            as: DerivedChildResult.self
        )

        self.status = "正在加密入库…"
        if try await !self.vault.hasPassword() {
            _ = try await self.vault.initializePassword(self.demoPassword)
        } else {
            // vault.pb 已存在（上次运行持久化）：新进程需先解锁，否则导入会抛 vaultLocked
            _ = try await self.vault.unlock(self.demoPassword)
        }
        try await self.vault.importMnemonic(
            address: derived.address,
            mnemonic: Data(mnemonic.value.utf8),
            privateKey: Data(derived.keypair.privateKey.utf8),
            pathPrefix: "m/44'/60'/0'/0/0",
            language: mnemonic.language
        )

        // 刷新地址列表，新钱包设为当前地址
        let account = self.makeAccount(address: derived.address)
        if !self.state.accounts.contains(where: { $0.address.caseInsensitiveCompare(derived.address) == .orderedSame }) {
            self.state.accounts.append(account)
        }
        self.state.currentAddress = derived.address
        self.status = "钱包已生成：\(derived.address)"
    }

    // MARK: - 按地址查看密钥（从 SwiftVault 解密读出）

    func revealKey(for address: String) async throws -> (privateKey: String, mnemonic: String) {
        let privateKey = try await self.vault.getPrivateKey(address: address, password: self.demoPassword)
        let mnemonic = try await self.vault.getMnemonic(address: address, password: self.demoPassword)
        return (
            String(decoding: privateKey, as: UTF8.self),
            String(decoding: mnemonic, as: UTF8.self)
        )
    }

    // MARK: - 私有

    private func makeAccount(address: String) -> WalletAccount {
        WalletAccount(address: address, chain: .eth, name: "Demo Wallet", isHD: false)
    }

    private func startBridgeIfNeeded() async throws {
        // initialize/start 幂等：重复调用复用已有 WebView，不重复创建。
        self.engine.initialize(config: WebviewBridgeConfig.bridge(named: "wallet-bridge"))
        try self.engine.start()
    }
}

// MARK: - JS 桥返回模型（与 wallet-bridge.js 返回值对应）

struct GeneratedMnemonic: Decodable {
    let value: String
    let language: String
}

struct DerivedChildResult: Decodable {
    let address: String
    let keypair: Keypair
    let path: Path?

    struct Keypair: Decodable {
        let privateKey: String
        let publicKey: String
    }

    struct Path: Decodable {
        let chain: Int64
        let account: Int
        let change: Int
        let index: Int
    }
}
