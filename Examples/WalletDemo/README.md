# WalletDemo

演示 `swift-toolkits` 五个模块的组合使用：

| 模块 | 在 demo 中的角色 |
| --- | --- |
| `SwiftWebviewBridge` | 隐藏 WebView 里的 jcc-wallet 加密库：生成助记词、派生 ETH 账户 |
| `SwiftVault` | 密码加密持久化私钥/助记词（Argon2id + AES-256-GCM） |
| `SwiftDappConnect` | 真实 WKWebView 中注入 EIP-1193 provider，DApp 与钱包通信 |
| `SwiftNft` | NFT 元数据/图片解析：DID 头像 VC → tokenURI/erc_info → 元数据 → 图片 URL |
| `SwiftDid` | 链上 DID 解析（did-bridge 隐藏 WebView）+ Profile/头像 VC 展示 |

## 功能

主界面按钱包存在与否自适应：

- **无钱包**：显示「生成钱包」按钮与提示。
- **已有钱包**：显示**地址列表**（地址缩写展示前后段如 `0xd65b…8bdb`，点击行切换当前地址、
  点「密钥」查看该地址完整私钥/助记词），并提供「新增钱包」按钮（再次生成新助记词派生新账户）。
- **DID 头像（示例）**：主界面「DID」区块按钮进入**二级全屏页**（与 DApp 页同形态），展示
  `did:swtc:…` 与 `did:ethr:…` 两个示例 DID 的头像：
  - 解析链：`resolveDid`（链上取档）→ `generateProfileVC`（读 preferredAvatar VC）→ SwiftNft
    元数据解析出图片 URL → 行内 AsyncImage 加载；EVM 头像的 `tokenURI(uint256)` 由 SwiftNft
    模块内 `EthTokenUriResolver`（eth_call）提供，RPC 端点由宿主经
    `rpcUrlsForChain` 闭包按 chainId 注入。
  - **SWTC ownership 兜底**：preferredAvatar 的 NFT 元数据不可解析时（如 `did:swtc:…` 示例的
    ETH NFT `tokenURI` 链上 revert），改用该 DID 自有的 SWTC ownership VC（`generateSwtcNft`
    → erc_info → IPFS 元数据 → 图片，演示两个模块组合）。
  - **缓存优先（全走 sqlite，不依赖 UserDefaults）**：DID 文档已落本地 sqlite 时跳过链上解析
    （不转圈）；解析成功的图片 URL 由 `fetchAndCacheNftMeta` 落 `nft_meta`（nft.sqlite），重启后
    `start()` 并行做**纯本地恢复**——文档/元数据已缓存直接出图，**头像图片文件落盘
    `Application Support/WalletDemo/avatars/`** 的连下载都省了；未缓存的 DID 链上解析**各并行、
    互不阻塞**，期间显示 loading，失败显示具体原因。
- **加载 DApp Demo**：全屏 WKWebView 加载本地 DApp 页面（`dapp.html`，英文内容），四个按钮：
  - `web3_clientVersion`：直接调 `window.ethereum.request(...)`
  - `web3_clientVersion (EIP-6963)`：监听 `eip6963:announceProvider` 按发现协议拿 provider 再调用
  - `eth_requestAccounts`：返回**当前选中地址**（在 App 里切换当前地址后重新调用即返回新地址）
  - `eth_signTransaction (转账签名)`：对示例 ETH 转账（0 地址转 1 ETH）签名——DApp 发起请求，
    原生经 **SwiftVault 取当前钱包私钥 → SwiftWallet 隐藏桥签名**，回传 raw signed tx 展示

签名链路：`dapp.html` → `window.ethereum.request` → `_tw_` 通道 → `EthMiddleware.signTransaction`
→ `DemoSecretProvider`（委托 `WalletService` 从 SwiftVault 解密）→ `SwiftWallet`（隐藏桥 JS 签名）。

钱包数据（助记词/私钥）经 SwiftVault 加密持久化，重启 App 自动加载已有钱包；
**当前选中地址持久化到 UserDefaults**，重启后恢复上次选择，而非默认第一个账户。

## 构建与运行

需要 [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）：

```bash
cd Examples/WalletDemo
xcodegen generate          # 生成 WalletDemo.xcodeproj（依赖路径 ../.. 指向仓库根）
open WalletDemo.xcodeproj
# 选择 iOS 模拟器运行；或命令行：
xcodebuild -project WalletDemo.xcodeproj -scheme WalletDemo \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## 实现要点（踩坑记录）

- **DApp 页编码（iOS 17 中文乱码，最终方案）**：页面内容改用**英文**，从源头规避
  非 ASCII 编码问题；加载仍用最稳方式——文件原始 UTF-8 字节 + UTF-8 BOM 前置 +
  `load(data, mimeType: "text/html", characterEncodingName: "utf-8", baseURL:)`。
  不要用 `loadHTMLString(String, baseURL:)`（Swift String 传参时 WebKit 编码推断不可靠）。
  改动后务必**卸载重装 App**（旧安装残留旧包）。
- **DApp 页 origin**：本地页面必须用 `load(Data...)` 的 `baseURL` 提供 http(s) origin
  （如 `https://dapp.example.com`）——H1 修复后 origin 按 `frameInfo.securityOrigin`
  实时推导，`file://` / `about:blank` 的请求会被拒绝。
- **provider 注入**：`loadProviderJs(token: interface.responseToken)` 必须在页面加载完成后
  （`didFinish`）注入；token 缺失时 native 回传 fail-closed。
- **eth_requestAccounts 需要账户**：中间件的 `requestAccounts` 必须有
  `setRequestAccountsCallback`（demo 直接返回 true 自动授权，真实 App 应弹确认），
  且 `DemoAccountProvider` 只返回当前选中账户；中间件按 `initialChain` 过滤账户
  （demo 用 `.eth`，与派生链一致）。
- **EIP-6963 验证**：provider 注入后即开始广播 `eip6963:announceProvider`（5s 周期 +
  响应 `eip6963:requestProvider`）；DApp 按发现协议拿 `e.detail.provider` 调用
  `request({method:'web3_clientVersion'})`，走与 `window.ethereum` 相同的
  `_tw_` → native → 回传链路。
- **vault 持久化**：`vault.pb` 存于 Application Support，重启后仍在。新进程导入前若
  密码已初始化必须先 `unlock`，否则抛 `VaultError.vaultLocked`。
- **demo 密码**：固定 `demo-password-1234`（仅演示；真实 App 应引导用户设置并放 Keychain）。
- **重置**：`simctl uninstall` 删除 App 即清空 vault 数据。

## 目录结构

```text
Examples/WalletDemo/
├── project.yml                  # xcodegen 工程描述（依赖本地 swift-toolkits 包）
├── WalletDemo.xcodeproj         # 生成的工程（xcodegen generate 可再生成）
└── WalletDemo/
    ├── WalletDemoApp.swift      # App 入口
    ├── ContentView.swift        # 主界面：地址列表/切换当前地址、按地址查看密钥、DApp/DID 头像入口
    ├── WalletService.swift      # SwiftVault + SwiftWebviewBridge 组合（生成/新增钱包、按地址查看密钥）
    ├── DemoProviders.swift      # DemoWalletState（地址列表/当前地址）+ DAppConnect 中间件桩 Provider
    ├── DappView.swift           # WKWebView + SwiftDappConnect 注入（含 eth_requestAccounts）
    ├── DidAvatarService.swift   # DID 头像服务：SwiftDid 解析 + SwiftNft 元数据/图片 + 三层缓存
    ├── DidAvatarView.swift      # DID 头像二级全屏页（AsyncImage + 本地文件直出）
    └── Resources/dapp.html      # DApp 页面（英文）：web3_clientVersion ×2 + eth_requestAccounts
```
