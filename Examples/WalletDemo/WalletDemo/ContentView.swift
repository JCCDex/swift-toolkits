import SwiftCore
import SwiftDappConnect
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var state: DemoWalletState
    @State private var showDapp = false
    @State private var showDidAvatar = false
    @State private var keyResult: KeyResult?
    @State private var errorText: String?
    @State private var didLoadExisting = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    if self.state.accounts.isEmpty {
                        Button {
                            Task { await self.addWallet() }
                        } label: {
                            Label("生成钱包", systemImage: "wallet.bifold")
                        }
                        Text("尚未生成钱包")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(self.state.accounts) { account in
                            AddressRow(
                                account: account,
                                isCurrent: self.state.currentAddress?.caseInsensitiveCompare(account.address) == .orderedSame,
                                onSwitch: { self.state.setCurrent(account.address) },
                                onReveal: { self.revealKey(for: account.address) }
                            )
                        }
                        Button {
                            Task { await self.addWallet() }
                        } label: {
                            Label("新增钱包", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("钱包地址（点击圆圈切换当前地址）")
                }

                Section {
                    NavigationLink {
                        HDWalletListView()
                    } label: {
                        Label("HD 钱包（根账户 + 子账户）", systemImage: "rectangle.stack.badge.plus")
                    }
                } header: {
                    Text("HD")
                }

                Section {
                    Button {
                        self.showDidAvatar = true
                    } label: {
                        Label("DID 头像（示例）", systemImage: "person.crop.circle")
                    }
                } header: {
                    Text("DID")
                }

                Section {
                    Button {
                        self.showDapp = true
                    } label: {
                        Label("加载 DApp Demo", systemImage: "globe")
                    }
                } header: {
                    Text("DApp")
                }

                if !self.wallet.status.isEmpty {
                    Section {
                        Text(self.wallet.status)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Wallet Demo")
            .fullScreenCover(isPresented: self.$showDapp) {
                DappScreen(wallet: self.wallet)
            }
            .fullScreenCover(isPresented: self.$showDidAvatar) {
                DidAvatarScreen()
            }
            .sheet(item: self.$keyResult) { result in
                KeySheet(result: result)
            }
            .alert("出错了", isPresented: .init(
                get: { self.errorText != nil },
                set: {
                    if !$0 {
                        self.errorText = nil
                    }
                }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(self.errorText ?? "")
            }
            .onAppear {
                self.loadExistingIfNeeded()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func loadExistingIfNeeded() {
        guard !self.didLoadExisting else { return }
        self.didLoadExisting = true
        Task {
            try? await self.wallet.loadExistingWallets()
        }
    }

    private func addWallet() async {
        do {
            try await self.wallet.addWallet()
        } catch {
            self.errorText = error.localizedDescription
        }
    }

    private func revealKey(for address: String) {
        Task {
            do {
                let value = try await wallet.revealKey(for: address)
                self.keyResult = KeyResult(address: address, value: value)
            } catch {
                self.errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - 地址行

struct AddressRow: View {
    let account: WalletAccount
    let isCurrent: Bool
    let onSwitch: () -> Void
    let onReveal: () -> Void

    /// 地址缩写：保留前 10 / 后 8 位，中间用 … 省略
    private static func shortAddress(_ address: String) -> String {
        guard address.count > 22 else { return address }
        return String(address.prefix(10)) + "…" + String(address.suffix(8))
    }

    var body: some View {
        HStack(spacing: 10) {
            // 圆圈 + 地址整体可点，扩大切换命中区
            Button(action: self.onSwitch) {
                HStack(spacing: 10) {
                    Image(systemName: self.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(self.isCurrent ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        // 地址缩写展示：保留前后段，中间省略（如 0x7b62279f...0b2b6b35）
                        Text(Self.shortAddress(self.account.address))
                            .font(.system(.caption, design: .monospaced))
                        Text(self.isCurrent ? "当前地址" : "点击切换当前地址")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("密钥", action: self.onReveal)
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - 密钥展示

struct KeyResult: Identifiable {
    let address: String
    let value: (privateKey: String, mnemonic: String)
    var id: String {
        self.address
    }
}

struct KeySheet: View {
    let result: KeyResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("地址") {
                    Text(self.result.address).font(.system(.body, design: .monospaced))
                }
                Section("私钥") {
                    Text(self.result.value.privateKey).font(.system(.caption, design: .monospaced))
                }
                Section("助记词") {
                    Text(self.result.value.mnemonic).font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("钱包密钥")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { self.dismiss() }
                }
            }
        }
    }
}

// MARK: - DApp 全屏页

struct DappScreen: View {
    @Environment(\.dismiss) private var dismiss
    let wallet: WalletService

    var body: some View {
        NavigationView {
            DappView(wallet: self.wallet)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("DApp Demo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { self.dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - HD 钱包列表（二级页：root address 列表 + 生成 HD 按钮）

/// HD 根账户列表页：显示所有 HD 根账户（`isHD && parentId == nil`），
/// 提供「生成 HD」按钮；点击根账户进入其子账户列表。
struct HDWalletListView: View {
    @EnvironmentObject private var wallet: WalletService
    @State private var roots: [WalletAccount] = []
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await self.generateHD() }
                } label: {
                    Label("生成 HD", systemImage: "plus.circle")
                }
                Text("生成 HD 钱包：根账户（SWTC）+ ETH/SWTC 子账户，私钥全部落 vault")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                if self.roots.isEmpty {
                    Text("尚无 HD 根账户")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(self.roots) { root in
                        NavigationLink {
                            HDSubAccountListView(root: root, wallet: self.wallet)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.shortAddress(root.address))
                                    .font(.system(.caption, design: .monospaced))
                                Text("HD 根账户 · \(root.chain.label)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("根账户（点击进入子账户列表）")
            }
        }
        .navigationTitle("HD 钱包")
        .task { await self.reload() }
        .alert("出错了", isPresented: .init(
            get: { self.errorText != nil },
            set: {
                if !$0 {
                    self.errorText = nil
                }
            }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(self.errorText ?? "")
        }
    }

    private func generateHD() async {
        do {
            _ = try await self.wallet.addHDWallet()
            await self.reload()
        } catch {
            self.errorText = error.localizedDescription
        }
    }

    /// 重新拉取 HD 根账户列表（观察流首帧即当前值）。
    private func reload() async {
        self.roots = await self.wallet.account.rootHDAccounts.firstValue() ?? []
    }

    private static func shortAddress(_ address: String) -> String {
        guard address.count > 22 else { return address }
        return String(address.prefix(10)) + "…" + String(address.suffix(8))
    }
}

// MARK: - HD 子账户列表（三级页：地址 / path / 密钥）

/// 某根账户的子账户列表（`parentId == root.id`）：每项显示地址、派生 path，
/// 并提供「密钥」查看（SwiftVault 解密）；顶部可继续派生子账户。
struct HDSubAccountListView: View {
    let root: WalletAccount
    @ObservedObject var wallet: WalletService
    @State private var children: [WalletAccount] = []
    @State private var keyResult: KeyResult?
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await self.deriveChild() }
                } label: {
                    Label("派生子账户", systemImage: "arrow.triangle.branch")
                }
            } header: {
                Text("根账户 \(Self.shortAddress(self.root.address))")
            }

            Section {
                if self.children.isEmpty {
                    Text("尚无子账户")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(self.children) { child in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.shortAddress(child.address))
                                    .font(.system(.caption, design: .monospaced))
                                Text(child.path?.derivationPath ?? "—")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("密钥") {
                                Task { await self.revealKey(for: child) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("子账户（地址 / path）")
            }
        }
        .navigationTitle("子账户")
        .task { await self.reload() }
        .sheet(item: self.$keyResult) { result in
            KeySheet(result: result)
        }
        .alert("出错了", isPresented: .init(
            get: { self.errorText != nil },
            set: {
                if !$0 {
                    self.errorText = nil
                }
            }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(self.errorText ?? "")
        }
    }

    /// 两步派生：deriveSubAccount（只派生）→ importSubAccount（落库）。
    private func deriveChild() async {
        _ = await self.wallet.deriveAndImportSubAccount(rootAccountId: self.root.id, chain: .eth)
        await self.reload()
    }

    private func reload() async {
        self.children = await self.wallet.account.subAccounts(of: self.root.id).firstValue() ?? []
    }

    private func revealKey(for child: WalletAccount) async {
        do {
            // 助记词存根账户地址下（importHdWallet 以根地址存 mnemonic），子账户只有私钥
            let value = try await self.wallet.revealKey(for: child.address, mnemonicFrom: self.root.address)
            self.keyResult = KeyResult(address: child.address, value: value)
        } catch {
            self.errorText = error.localizedDescription
        }
    }

    private static func shortAddress(_ address: String) -> String {
        guard address.count > 22 else { return address }
        return String(address.prefix(10)) + "…" + String(address.suffix(8))
    }
}
