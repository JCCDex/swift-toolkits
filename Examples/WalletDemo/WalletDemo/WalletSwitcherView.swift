import SwiftCore
import SwiftUI

/// 切换地址弹窗（对图片「My Wallet」的简化实现）。
/// - 左侧：链导航（点选高亮）；右侧：当前链下的子钱包地址，点击切换当前地址。
/// - 数据来自 `DemoWalletState`（由 SwiftAccount 观察流驱动）：`accounts` + `currentAddress` + `setCurrent`。
struct WalletSwitcherView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var state: DemoWalletState
    /// 当前选中的链（默认取当前地址所在链，缺省第一个链）。
    @State private var selectedChain: ChainType
    /// Derive 时的根钱包候选（点击 Derive 先加载再弹出选择）。
    @State private var rootCandidates: [WalletAccount] = []
    @State private var showRootPicker = false
    @State private var errorText: String?

    init() {
        // 无当前地址时用 `.eth` 兜底；实际在 onAppear 里根据 currentAccount 校正。
        _selectedChain = State(initialValue: .eth)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("My Wallet")
                    .font(.headline)
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // 左侧链导航 + 右侧账户列表
            HStack(spacing: 0) {
                self.chainRail
                Divider()
                self.accountPanel
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { self.correctInitialChain() }
        .confirmationDialog(
            "从哪个根钱包派生 \(self.selectedChain.label) 子账户？",
            isPresented: self.$showRootPicker,
            titleVisibility: .visible
        ) {
            ForEach(self.rootCandidates) { root in
                Button("根 \(Self.shortAddress(root.address)) · \(root.chain.label)") {
                    Task { await self.derive(from: root.id) }
                }
            }
            Button("取消", role: .cancel) {}
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

    // MARK: - 左侧链导航

    private var chainRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                ForEach(ChainType.allCases, id: \.self) { chain in
                    ChainBadge(
                        chain: chain,
                        isSelected: chain == self.selectedChain
                    ) {
                        self.selectedChain = chain
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
        }
        .frame(width: 72)
    }

    // MARK: - 右侧账户面板

    private var accountPanel: some View {
        // 只显示子钱包地址：排除 HD 根账户（isHDRoot：isHD && parentId == nil）。
        let accounts = self.state.accounts.filter { $0.chain == self.selectedChain && !$0.isHDRoot }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(self.selectedChain.label)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.top, 12)

                if accounts.isEmpty {
                    Text("该链下暂无子钱包")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(accounts) { account in
                        AccountCard(
                            account: account,
                            isCurrent: self.state.currentAddress?.caseInsensitiveCompare(account.address) == .orderedSame,
                            onSelect: { self.select(account) }
                        )
                    }
                }

                // 派生按钮：位于子账户列表下方（对齐图片布局）
                Button {
                    Task { await self.derive() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Derive Account")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(10)
                }
                .buttonStyle(.borderless)
                .padding(.bottom, 12)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 动作

    /// 校正选中链：若当前地址所在链不在 `ChainType.allCases`（理论不会），回退 `.eth`。
    private func correctInitialChain() {
        if let current = self.state.currentAccount, !self.state.accounts.isEmpty {
            self.selectedChain = current.chain
        }
    }

    /// 点击子钱包地址 → 切换当前地址并关闭。
    private func select(_ account: WalletAccount) {
        self.state.setCurrent(account.address)
        self.dismiss()
    }

    /// 点击 Derive Account：加载全部 HD 根钱包候选并弹出选择框，由用户选定根钱包。
    private func derive() async {
        let roots = await self.wallet.account.rootHDAccounts.firstValue() ?? []
        guard !roots.isEmpty else {
            self.errorText = "尚无 HD 根钱包，请先通过「生成钱包」创建"
            return
        }
        self.rootCandidates = roots
        self.showRootPicker = true
    }

    /// 用户选定根钱包后：从该根派生子账户并保存到本地（`deriveAndImportSubAccount`
    /// 两步：deriveSubAccount 只派生 → importSubAccount 落库；链取左侧当前选中）。
    private func derive(from rootId: String) async {
        _ = await self.wallet.deriveAndImportSubAccount(rootAccountId: rootId, chain: self.selectedChain)
        // 观察流自动刷新右侧列表
    }

    private static func shortAddress(_ address: String) -> String {
        guard address.count > 22 else { return address }
        return String(address.prefix(6)) + "…" + String(address.suffix(4))
    }
}

// MARK: - 链徽章（左侧导航）

/// 链图标徽章：圆形底色 + 链名首字母；选中时高亮描边。
private struct ChainBadge: View {
    let chain: ChainType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(self.isSelected ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(self.isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                    Text(String(self.chain.label.prefix(1)))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(self.isSelected ? .accentColor : .secondary)
                }
                Text(self.chain.label)
                    .font(.system(size: 9))
                    .foregroundColor(self.isSelected ? .accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - 账户卡片（右侧列表）

/// 单个子钱包地址卡片：名称 + 地址缩写 + 链标签；当前地址高亮，点击切换。
private struct AccountCard: View {
    let account: WalletAccount
    let isCurrent: Bool
    let onSelect: () -> Void

    private static func shortAddress(_ address: String) -> String {
        guard address.count > 22 else { return address }
        return String(address.prefix(6)) + "…" + String(address.suffix(4))
    }

    var body: some View {
        Button(action: self.onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(self.account.name.isEmpty ? "账户" : self.account.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        if self.account.isHD {
                            Text("HD")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    Text(Self.shortAddress(self.account.address))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    // 路径信息：HD 子账户显示 BIP44 派生路径，根账户/传统账户显示 "—"
                    Text(self.account.path?.derivationPath ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(.systemGray))
                }
                Spacer()
                Text("0 \(self.account.chain.label)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Image(systemName: self.isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(self.isCurrent ? .accentColor : Color(.systemGray3))
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
