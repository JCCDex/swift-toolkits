# SwiftWebviewBridge

`kotlin-toolkits` 中 `:webview-bridge` 模块的 Swift 移植：以 iOS 惯用方式复刻「隐藏 WebView 运行时 + JS Promise 通信」能力（`WKWebView` + `WKScriptMessageHandler`），供 `did`、`wallet` 等 SDK 复用。

## 设计原则

1. **协议不变、平台适配**：Native ↔ JS 之间的消息格式、方法名、就绪语义与 Kotlin 完全一致，只替换承载通道（Android `addJavascriptInterface` → iOS `WKScriptMessageHandler`）。
2. **行为对齐**：默认超时（30s / 15s）、结果字符串化规则、错误响应格式、destroy 后可重建等行为逐一对齐 Kotlin 测试契约。
3. **Swift 化 API**：`suspend` → `async throws`，`JSONObject` → `[String: Any]`/`Codable`，`Gson` → `JSONDecoder`。

## 快速开始

```swift
import SwiftWebviewBridge

// 引擎层（EngineBridge 协议实现）：按 bridgeFileName 参数化
let engine = WebViewBridgeEngine(bridgeFileName: "wallet-bridge")
try engine.start() // 内部完成 client.initialize(bundle:config:) + 启动隐藏 WebView

// 字典参数：生成助记词
let mnemonic = try await engine.call(
    method: "generateMnemonic",
    params: ["length": 128]
)

// 类型化返回：解析 JS 返回的 JSON
struct Derived: Decodable { let address: String; let keypair: Keypair }
let result: Derived = try await engine.callTyped(
    method: "deriveChild",
    params: ["mnemonic": "...", "chain": 60],
    asType: Derived.self
)

engine.destroy()
```

宿主若需自持 client 直连（如 SwiftDid 加载独立 did-bridge 页面）：

```swift
let client = WebViewBridgeClient()
client.initialize(bundle: .main, config: WebViewBridgeConfig.bridge(named: "did-bridge"))
try client.start()

let raw = try await client.callJSMethod(method: "ping", params: nil)
let typed: DidStatResult = try await client.callJSMethodAs(
    method: "didStat", params: ["did": did], asType: DidStatResult.self
)
```

## 模块结构

```text
Sources/SwiftWebviewBridge/
├── WebViewBridgeEngine.swift        // 引擎层（EngineBridge 协议实现，包装 client）
├── WebViewBridgeClient.swift        // 核心：生命周期 + 调用编排
├── WebViewBridgeConfig.swift        // 配置与 JS 脚本生成
├── WebViewBridgeError.swift         // 错误类型
├── PromiseGateway.swift             // 回调表 / 就绪监听 / 结果解析
├── BridgeMessageHandler.swift       // WKScriptMessageHandler 适配
├── WebViewRuntime.swift             // WKWebView 抽象（可测试性）
└── Resources/
    └── bridge/
        ├── wallet-bridge.html / did-bridge.html
        ├── wallet-bridge.js / did-bridge.js
        └── vendor/*.min.js          // 与 Kotlin assets 相同
```

## 主要 API

| 类别 | API |
| --- | --- |
| 生命周期 | `start()`、`destroy()`（client 另含 `initialize(bundle:config:)`） |
| 基础调用 | `call(method:params:timeoutMs:readyWaitMs:)` / `callJSMethod(...)`（client 层） |
| 类型化调用 | `callTyped(method:params:asType:timeoutMs:readyWaitMs:)` / `callJSMethodAs(...)`（client 层） |
| 配置 | `WebViewBridgeConfig.bridge(named:)` / `WebViewBridgeConfig(bridgeFileName:...)` |

## 说明

- **配置必填**：`WebViewBridgeConfig.bridgeFileName` 无默认值，`initialize` 的 `config` 也必须显式传入（避免静默加载错误的 bridge 文件）。
- **主线程约束**：`WebViewBridgeEngine` / `WebViewBridgeClient` 标记 `@MainActor`，`WKWebView` 的访问由编译器强制在主线程。
- **资源打包**：`Package.swift` 通过 `.copy("Resources/bridge")` 打包 `wallet-bridge.html` / `did-bridge.html` 与 vendor JS。
- **真实 WebView 测试**：iOS 模拟器上首次调用会冷启动 WebContent 进程，CI 已通过预热模拟器、串行执行与失败自动重试来降低 flaky。

## 设计文档

完整设计稿（Kotlin 架构解析、Swift 代码草案、通信协议与 JS、迁移与测试策略）：

[Docs/WebviewBridge-Swift/README.md](../../Docs/WebviewBridge-Swift/README.md)
