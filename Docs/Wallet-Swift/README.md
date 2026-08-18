# Wallet · Swift 移植设计稿

本文档是 `kotlin-toolkits` 中 `:wallet` 模块的 Swift 版本设计。目标是把 Kotlin 版「通过隐藏 WebView 调用钱包 JS 能力」以 Swift/iOS 惯用方式复刻：助记词生成/校验、子账户派生、地址派生与校验、签名与验签，并作为 `SwiftDappConnect` 的 `WalletSigning` 实现。

> 状态：设计稿。文中 Swift 代码为设计示例，用于指导实现，尚未作为可编译 target 落库。

## 设计原则

1. **复用 SwiftWebviewBridge 作为传输层**：Kotlin 的 `:wallet` 依赖 `:webview-bridge` 的隐藏 WebView 与 `wallet-bridge.html`；Swift 侧 `SwiftWebviewBridge` 已内置 `wallet-bridge.html` 与全部钱包 JS 资产（jcc-wallet / jingtum-lib / eth-sig-util / ethereumjs-tx），本模块只做**类型化封装**，不重复造桥。
2. **行为对齐 Kotlin WalletSdk**：方法名、参数、返回 JSON 结构与 Kotlin 完全一致；默认超时（30s / 15s）、未初始化抛错、destroy 后可重建等行为对齐。
3. **Swift 化 API**：`suspend` → `async throws`，`JSONObject` → `[String: Any]` / `Encodable`，Gson → `JSONDecoder`，单例 `object WalletSdk` → `@MainActor` 单例 `SwiftWallet.shared`。
4. **对接 SwiftDappConnect**：本模块实现 `WalletSigning` 协议（`personalSign` / `signTypedData` / `signEthTransaction` / `signSwtcTransaction` / `multiSign` / `decrypt` 等），让中间件从「桩实现」切换到真实签名能力。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-kotlin-architecture.md](01-kotlin-architecture.md) | Kotlin 版模块解析：WalletSdk 全量 API、模型、隐藏 WebView 运行时、JS 方法清单与测试基线 |
| [02-swift-design.md](02-swift-design.md) | Swift 版设计：模块布局、模型、`SwiftWallet` 完整代码草案、并发与安全要点 |
| [03-protocol-and-js.md](03-protocol-and-js.md) | wallet-bridge.js 方法协议（参数/返回）、与 Kotlin 的差异与 JS 缺口、密钥传输安全 |
| [04-migration-and-testing.md](04-migration-and-testing.md) | Kotlin → Swift 逐项对照表、实现坑、测试策略（FakeRuntime 注入）与实施清单 |

## 快速接入（设计预览）

```swift
import SwiftWallet

// 首次使用前初始化（幂等；内部启动隐藏 WebView 加载 wallet-bridge.html）
try await SwiftWallet.shared.start()

// 生成助记词
let mnemonic: Mnemonic = try await SwiftWallet.shared.generateMnemonic(length: 128)

// 派生 ETH 子账户（chain = BIP44 链码，与 SwiftDappConnect ChainType.eth.bip44Code 一致）
let subWallet: SubWallet = try await SwiftWallet.shared.deriveChild(
    mnemonic: mnemonic.value,
    chain: 2_147_483_708   // ChainType.eth.bip44Code
)

// 作为 SwiftDappConnect 的签名实现
let signing: any WalletSigning = SwiftWallet.shared
```

## 与 Kotlin 差异一览

| 维度 | Kotlin | Swift |
| --- | --- | --- |
| 传输层 | `WebviewBridgeClient`（Android 隐藏 WebView） | `WebviewBridgeEngine.shared`（SwiftWebviewBridge，WKWebView） |
| 桥资产 | `wallet-bridge.html`（Android assets） | `SwiftWebviewBridge` bundle 内置同名文件（可直接复用） |
| 入口 | `object WalletSdk` + `initialize(context)` | `final class SwiftWallet` + `.shared`（无需 Context） |
| 并发 | `suspend` | `async throws`（@MainActor） |
| 参数 | `JSONObject` | `[String: Any]` / `Encodable` |
| 反序列化 | Gson | `JSONDecoder` |
| 签名对接 | `WalletSdk` 被 DApp 层直接调用 | 实现 `WalletSigning` 协议注入中间件 |

## 关键设计点

- **零 JS 改动**：直接复用现有 `wallet-bridge.js`，Swift 只做方法名 → 类型化 API 的映射。
- **模型镜像**：`Keypair` / `Path` / `Mnemonic` / `SubWallet` / `GenerateHDWalletResult` / `TraditionalDeriveResult` 与 Kotlin 数据类一一对应（`Decodable`）。
- **链码一致性**：`chain` 参数用 `Int64` BIP44 链码，与 `SwiftDappConnect.ChainType.bip44Code` 共用同一套数值。
- **安全注意**：私钥/助记词以 `String` 跨 JS 桥传输且不可擦除（同 Kotlin 现状），本模块文档标注内存安全边界；桥资产内私钥相关方法（personalSign 等）仅由宿主签名流程调用。
