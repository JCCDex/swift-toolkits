# DApp Connect · Swift 移植设计稿

本文档是 `kotlin-toolkits` 中 `:dapp-connect` 模块的 Swift 版本设计。目标是把 Kotlin 版「供 WebView 与 DApp 通过 `window.ethereum` / `window.ccdao` 进行连接、签名和交易」的能力以 Swift/iOS 惯用方式复刻：中间件层（EVM / SWTC）、账户/密钥/节点/NFT 提供者接口，以及 EIP-1193 provider JS 注入。

> 状态：设计稿。文中 Swift 代码为设计示例，用于指导实现，尚未作为可编译 target 落库。

## 设计原则

1. **协议不变、平台适配**：DApp ↔ Native 之间的 postMessage 消息格式、nonce 请求队列、响应结构、方法名与 Kotlin 完全一致，只替换承载通道（Android `addJavascriptInterface` + `WebMessagePort` → iOS legacy `WKScriptMessageHandler` + `_ccdaoSettle(nonce, payload, token)` 回传）。
2. **行为对齐**：错误码（4001 / 4902 / -1）、强制 requestAccounts 回调（M-06）、origin 校验（M-05）、地址去重/链过滤、缓存窗口等行为逐一对齐 Kotlin 契约与测试。
3. **Swift 化 API**：`suspend` → `async throws`，`Flow` → `AsyncStream`/`AsyncSequence`，`StateFlow` → actor 状态，`JSONObject` → `Codable`/`[String: Any]`，线程约束 → `@MainActor`。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-kotlin-architecture.md](01-kotlin-architecture.md) | Kotlin 版模块逐文件解析：类职责、消息路由、中间件、Provider、响应通道、安全规则与测试基线 |
| [02-swift-design.md](02-swift-design.md) | Swift 版设计：模块布局、类型与完整代码草案、并发模型（`@MainActor` + `async/await`） |
| [03-protocol-and-js.md](03-protocol-and-js.md) | DApp ↔ Native 通信协议、provider JS 注入与 iOS 变体、URL/Origin 安全 |
| [04-migration-and-testing.md](04-migration-and-testing.md) | Kotlin → Swift 逐项对照表、实现注意点/坑、测试策略与实施清单 |

## 快速接入（设计预览）

```swift
import SwiftDappConnect

// 宿主提供 Provider 与中间件
let eth = DAppConnectSdk.createEthMiddleware(
    accountProvider: accounts,
    secretProvider: secrets,
    nodeProvider: nodes,
    chainProvider: chainSwitcher
)
let swtc = DAppConnectSdk.createSwtcMiddleware(
    accountProvider: accounts,
    secretProvider: secrets,
    nodeProvider: nodes
)

// 先创建 interface（持有 responseToken，M1/M2）
let interface = DAppConnectSdk.createWebAppInterface(
    webView: webView,
    ethMiddleware: eth,
    swtcMiddleware: swtc,
    accountProvider: accounts,
    secretProvider: secrets
)

// 每个页面加载时注入 provider 与初始化 JS（provider 必须带 interface.responseToken）
let providerJs = DAppConnectSdk.loadProviderJs(token: interface.responseToken)
let initJs = interface.loadInitJs(chainIdHex: "0x38", rpcUrl: "https://eth-rpc.example.com")
interface.installResponseChannel()   // provider JS 注入完成后调用（C-03）
// origin 无需接线：按消息从 frameInfo.securityOrigin 自动推导（M-05 / H1）
```

## 与 Kotlin 差异一览

| 维度 | Kotlin | Swift |
| --- | --- | --- |
| JS 注入接口 | `addJavascriptInterface(wai, "_tw_")` | `WKUserContentController.add(handler, name: "_tw_")` + 适配脚本 |
| JS → Native | `window._tw_.postMessage(json)` | `window.webkit.messageHandlers._tw_.postMessage(json, reply)` |
| Native → JS 响应 | `WebMessagePort` 握手（C-03） | `evaluateJavaScript` 调 `window._ccdaoSettle(nonce, payload, token)`（token 鉴权，M1） |
| 并发 | `CoroutineScope(Dispatchers.IO)` + `Flow` | `@MainActor` + `Task` + `AsyncStream` |
| 参数/结果 | `org.json.JSONObject` | `Codable` / `[String: Any]` |
| 密钥 | `WalletSdk`（模块内调用） | `WalletSigning` 协议（宿主接线，本仓库 `SwiftVault` 供钥） |
| DID | `DidSdk`（注入） | `DidSDK` 协议（宿主接线） |
