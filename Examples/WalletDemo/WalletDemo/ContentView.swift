import SwiftCore
import SwiftDappConnect
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var state: DemoWalletState
    @State private var showDapp = false
    @State private var showDidAvatar = false
    @State private var showWalletSwitcher = false
    @State private var errorText: String?
    @State private var didLoadExisting = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    if let current = self.state.currentAccount {
                        Button {
                            self.showWalletSwitcher = true
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.12))
                                        .frame(width: 44, height: 44)
                                    Text(String(current.chain.label.prefix(1)))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("当前地址")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(Self.shortAddress(current.address))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                                Spacer()
                                Text("切换")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.accentColor)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.primary)
                    } else {
                        Text("尚未选择地址")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("当前地址")
                }

                // 仅在没有任何账户时显示「生成钱包」入口；已有账户（含当前地址）时
                // 不再显示钱包/新增钱包按钮——地址管理统一走切换弹窗（见 review demo 需求）。
                if self.state.accounts.isEmpty {
                    Section {
                        Button {
                            Task { await self.addWallet() }
                        } label: {
                            Label("生成钱包", systemImage: "wallet.bifold")
                        }
                        Text("尚未生成钱包")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } header: {
                        Text("钱包")
                    }
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
            .sheet(isPresented: self.$showWalletSwitcher) {
                WalletSwitcherView()
                    .environmentObject(self.wallet)
                    .environmentObject(self.state)
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

    /// 地址缩写：保留前 10 / 后 8 位，中间用 … 省略。
    private static func shortAddress(_ address: String) -> String {
        guard address.count > 22 else { return address }
        return String(address.prefix(10)) + "…" + String(address.suffix(8))
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
