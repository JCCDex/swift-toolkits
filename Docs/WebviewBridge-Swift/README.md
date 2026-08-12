# Webview Bridge · Swift 移植设计稿

本文档是 `kotlin-toolkits` 中 `:webview-bridge` 模块的 Swift 版本设计。目标是把 Kotlin 版「隐藏 WebView 运行时 + JS Promise 通信能力」以 Swift/iOS 惯用方式复刻，供 `did`、`wallet` 等 SDK 复用。

> 状态：设计稿。文中 Swift 代码为设计示例，用于指导实现，尚未作为可编译 target 落库。

## 设计原则

1. **协议不变、平台适配**：Native ↔ JS 之间的消息格式、方法名、就绪语义与 Kotlin 完全一致，只替换承载通道（Android `addJavascriptInterface` → iOS `WKScriptMessageHandler`）。
2. **行为对齐**：默认超时（30s / 15s）、结果字符串化规则、错误响应格式、destroy 后可重建等行为逐一对齐 Kotlin 测试契约。
3. **Swift 化 API**：`suspend` → `async throws`，`JSONObject` → `[String: Any]`/`Codable`，`Gson` → `JSONDecoder`，单例 `object` → `@MainActor` 单例。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-kotlin-architecture.md](01-kotlin-architecture.md) | Kotlin 版模块逐文件解析：类职责、启动/调用/就绪/销毁流程、资产与测试基线 |
| [02-swift-design.md](02-swift-design.md) | Swift 版设计：模块布局、类型与完整代码草案、并发模型（`@MainActor` + `async/await`） |
| [03-protocol-and-js.md](03-protocol-and-js.md) | Native ↔ JS 通信协议、JS 适配层注入、资源打包与加载、ATS 说明 |
| [04-migration-and-testing.md](04-migration-and-testing.md) | Kotlin → Swift 逐项对照表、实现注意点/坑、测试策略与实施清单 |

## 快速接入（设计预览）

```swift
import SwiftWebviewBridge

let engine = WebviewBridgeEngine.shared
engine.initialize(
    bundle: .main,
    config: WebviewBridgeConfig.bridge(named: "wallet-bridge")
)

// 字典参数：生成助记词
let mnemonic = try await engine.callJsMethod(
    method: "generateMnemonic",
    params: ["length": 128]
)

// Encodable 参数（推荐）：类型安全，编译期校验
struct DeriveRequest: Encodable {
    let mnemonic: String
    let chain: Int
}
let request = DeriveRequest(mnemonic: "...", chain: 60)

// 类型化返回：解析 JS 返回的 JSON
struct Derived: Decodable { let address: String; let keypair: Keypair }
let result = try await engine.callJsMethodAs(
    method: "deriveChild",
    params: request,
    as: Derived.self
)

engine.destroy()
```

## 与 Kotlin 差异一览

| 维度 | Kotlin | Swift |
| --- | --- | --- |
| 承载 WebView | `android.webkit.WebView` | `WKWebView` |
| JS 注入接口 | `addJavascriptInterface(gateway, "JSBridge")` | `WKUserContentController` + 适配脚本 |
| JS → Native | `window.JSBridge.onPromiseResult(...)` | `window.webkit.messageHandlers.onPromiseResult.postMessage(...)` |
| Native → JS | `evaluateJavascript(js, null)` | `evaluateJavaScript(js)` |
| 并发 | `suspend` + `withTimeout` + `suspendCancellableCoroutine` | `async throws` + 网关内超时任务 |
| 参数/结果 | `org.json.JSONObject` | `[String: Any]` / `Codable` |
| 反序列化 | Gson | `JSONDecoder` |
| 线程约束 | `Handler(Looper.getMainLooper())` | `@MainActor`（编译期强制） |
| 单例 | `object WebviewBridgeEngine` | `final class WebviewBridgeEngine` + `.shared` |
