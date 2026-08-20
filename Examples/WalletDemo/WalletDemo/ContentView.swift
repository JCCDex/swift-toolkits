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
