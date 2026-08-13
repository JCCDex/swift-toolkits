# SwiftDappConnect

`kotlin-toolkits` 中 `:dapp-connect` 模块的 Swift 移植：供 WKWebView 与 DApp 通过 `window.ethereum` / `window.ccdao` 进行连接、签名和交易，包括中间件层（EVM / SWTC）、账户/密钥/节点/NFT 提供者接口，以及 EIP-1193 provider JS 注入。

## 设计原则

1. **协议不变、平台适配**：DApp ↔ Native 之间的 postMessage 消息格式、nonce 请求队列、响应结构、方法名与 Kotlin 完全一致，只替换承载通道（Android `addJavascriptInterface` + `WebMessagePort` → iOS legacy `WKScriptMessageHandler` + `_ccdaoSettle` 回传）。
2. **行为对齐**：错误码（4001 / 4902 / -1）、强制 requestAccounts 回调（M-06）、origin 校验（M-05）、HD 根过滤、缓存窗口等行为逐一对齐 Kotlin 契约。
3. **Swift 化 API**：`suspend` → `async throws`，`Flow` → `AsyncStream`，线程约束 → `@MainActor`；签名 / DID 抽象为宿主注入的协议。

## 快速开始

```swift
import SwiftDappConnect
import WebKit

// 宿主提供 Provider 与签名能力
let eth = DAppConnectSdk.createEthMiddleware(
    accountProvider: accounts,
    secretProvider: secrets,
    nodeProvider: nodes,
    chainProvider: chainSwitcher,
    signing: walletSigning
)
let swtc = DAppConnectSdk.createSwtcMiddleware(
    accountProvider: accounts,
    secretProvider: secrets,
    nodeProvider: nodes,
    signing: walletSigning
)

let interface = DAppConnectSdk.createWebAppInterface(
    webView: webView,
    ethMiddleware: eth,
    swtcMiddleware: swtc,
    accountProvider: accounts,
    secretProvider: secrets
)

// 页面加载时：注入 provider + 初始化 JS，并接线 origin（M-05）
webView.evaluateJavaScript(DAppConnectSdk.loadProviderJs())
webView.evaluateJavaScript(DAppConnectSdk.loadInitJs(chainIdHex: "0x38", rpcUrl: "https://eth-rpc.example.com"))
interface.setOrigin("https://dapp.example.com")

// 账户切换后推送地址
webView.evaluateJavaScript(DAppConnectSdk.loadAddressJs(address: newAddress, isSwtc: false))
```

> `createWebAppInterface` 会自动注册 `_tw_` 消息处理器并注入 `window._tw_` 适配脚本（对应设计稿 C-03 的 `installResponseChannel`），宿主无需额外调用。

## 模块结构

```text
Sources/SwiftDappConnect/
├── DAppConnectSdk.swift          // 统一入口：工厂 / JS 生成 / URL 安全
├── WebAppInterface.swift         // @MainActor 消息路由（legacy WKScriptMessageHandler + _ccdaoSettle 回传）
├── NativeResponseChannel.swift   // {nonce, result|error} payload 构造
├── WebOrigin.swift               // origin 归一化 + WALLET_INTERNAL 哨兵
├── AsyncSequence+First.swift     // AsyncStream 取首个元素辅助
├── middleware/
│   ├── MiddlewareInterfaces.swift // Eth/Swtc 协议 + WalletSigning + DidSDK
│   ├── EthMiddleware.swift       // EVM 方法实现
│   └── SwtcMiddleware.swift      // SWTC 方法实现
├── provider/
│   ├── Interfaces.swift          // Account/Secret/Node/Chain/Nft Provider
│   └── CachingSecretProvider.swift
├── model/
│   ├── DAppMethod.swift
│   └── Models.swift              // ChainType / WalletAccount / Path / 错误 / RPC / NFT
└── Resources/
    └── ccdao-eip1193-provider-ios.js  // EIP-1193 provider（iOS 传输变体）
```

## 主要 API

| 类别 | API |
| --- | --- |
| 中间件工厂 | `createEthMiddleware(...)` / `createSwtcMiddleware(...)` |
| 桥接入口 | `createWebAppInterface(webView:...)`（自动注册 `_tw_` 与适配脚本） |
| JS 生成 | `loadProviderJs()` / `loadInitJs(chainIdHex:rpcUrl:)` / `loadAddressJs(address:isSwtc:)` / `loadUpdateChainIdJs(...)` / `loadEip6963IconOverrideJs(...)` |
| 安全 | `isSafeUrl(_:)` / `WebOrigin.normalize(_:)` / `WebOrigin.walletInternal` |
| Provider | `AccountProvider` / `SecretProvider` / `NodeProvider` / `ChainProvider` / `NftProvider` |
| 缓存 | `CachingSecretProvider`（5s 批次窗口 / 20s 上限 / clearCache） |

## Notes

- **配置必填**：所有 Provider 与 `WalletSigning` / `DidSDK` 均由宿主注入，模块不依赖具体钱包实现（`SwiftVault` 可作 `SecretProvider` 后端）。
- **主线程约束**：`WebAppInterface` 与中间件标记 `@MainActor`；消息回传统一经 `evaluateJavaScript` 调 `window._ccdaoSettle`（带 nonce 的 JSON 字符串）。
- **错误码**：`userRejected→4001`、`chainNotSupported→4902`、通用错误 `-1`。
- **安全**：postMessage 拒绝空白/非安全 origin（M-05）；原生内部取密钥用 `WebOrigin.walletInternal`（M-18）。
- **对 Kotlin 的显式改进**：provider JS 的 `requestQueue` 增加 60s 超时兜底并防止 timer 泄漏；bridge 不可用统一回 `{code:-1,message}`。

## Design Docs

完整设计稿（Kotlin 架构解析、Swift 设计、通信协议与 JS、迁移与测试策略）：

[Docs/DappConnect-Swift/README.md](../../Docs/DappConnect-Swift/README.md)
