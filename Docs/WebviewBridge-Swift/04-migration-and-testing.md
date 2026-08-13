# 04 · 迁移对照、实现注意点与测试策略

## 1. Kotlin → Swift 逐项对照

| 类别 | Kotlin | Swift |
| --- | --- | --- |
| 承载 WebView | `android.webkit.WebView` | `WKWebView` |
| 配置类型 | `data class WebviewBridgeConfig` | `struct WebviewBridgeConfig` |
| 唯一入口 | `object WebviewBridgeEngine` | `final class WebviewBridgeEngine` + `static let shared` |
| 客户端 | `class WebviewBridgeClient` | `@MainActor final class WebviewBridgeClient` |
| Promise 网关协议 | `IPromiseGateway` | `PromiseGateway`（`@MainActor`，内部类型） |
| 网关单例 | `object JsPromiseGateway` | Client 持有网关实例（单例由 Engine 保证） |
| JS 接口注入 | `addJavascriptInterface(gateway, "JSBridge")` | `WKUserContentController.add(handler, name: ...)` + 适配脚本 |
| JS → Native | `@JavascriptInterface onPromiseResult/onBridgeReady` | `WKScriptMessageHandler.userContentController(_:didReceive:)` |
| Native → JS | `webView.evaluateJavascript(js, null)` | `webView.evaluateJavaScript(js)`（async） |
| 页面加载 | `loadUrl("file:///android_asset/...")` | `loadFileURL(_:allowingReadAccessTo:)` |
| 只允许本地资源 | `shouldOverrideUrlLoading` | `decidePolicyFor navigationAction` |
| 页面完成回调 | `onPageFinished` | `WKNavigationDelegate.didFinish` |
| 就绪兜底脚本 | `evaluateJavascript("if(window.JSBridge && ...)")` | 同语义 JS，经适配脚本转发 |
| 参数 | `JSONObject?` | `[String: Any]?`（可加 `Encodable` 重载） |
| 方法/ID 转义 | `JSONObject.quote(...)` | `JSONSerialization` 生成 JS 字符串字面量 |
| 结果解析 | `JSONObject` + `toString()` | `JSONSerialization` + 字符串化规则一致 |
| 类型化结果 | Gson `fromJson(raw.trim(), clazz)` | `JSONDecoder().decode(T.self, ...)` |
| 异步 | `suspend fun` + coroutines | `async throws` + `withCheckedThrowingContinuation` |
| 超时 | `withTimeout` | `PromiseGateway.waitForReady(timeoutMs:)` + `register()` 内 `timeoutTask`（`Task.sleep`） |
| 取消清理 | `invokeOnCancellation` | `withTaskCancellationHandler` + `ContinuationBox`（保证 onCancel 路径安全恢复续体，避免泄漏） |
| 取消工具 | 无（Kotlin 无"强制性续体"概念） | `ContinuationBox<T>`（`@unchecked Sendable`，恰好一次恢复） |
| 线程 | `Handler(Looper.getMainLooper())` | `@MainActor`（编译期） |
| 并发容器 | `ConcurrentHashMap` / `CopyOnWriteArrayList` | 主线程字典（消息回调天然串行） |
| 缓存 | `LOAD_NO_CACHE` | `websiteDataStore = .nonPersistent()` |
| 隐藏显示 | `visibility = INVISIBLE` | `isHidden = true`，frame 零尺寸 |
| 销毁 | `destroy()` 系列调用 | `stopLoading` + `loadBlank` + 移除 handler + nil + `clearAll` |
| console | `WebChromeClient.onConsoleMessage`（默认关） | console 转发脚本（默认关） |
| 测试注入 | 构造注入 `gateway` / `webViewFactory` | 构造注入 `gateway` / `runtimeFactory` |

## 2. 实现注意点与坑

### 2.1 `WKScriptMessageHandler` 强引用与泄漏

`userContentController.add(handler, name:)` 会**强持有** handler，handler 又持有 client（弱 delegate 可断环）。销毁时**必须**调用 `removeScriptMessageHandler(forName:)`，否则 WebView 无法释放。

### 2.2 `WKWebView` 只能在主线程使用

Swift 6 下把 Client 标 `@MainActor` 从编译期解决；调用方在后台线程需自行切换：

```swift
let result = try await MainActor.run {
    try await WebviewBridgeEngine.shared.callJsMethod(method: "...")
}
```

### 2.3 消息通道与页面加载方式绑定

`window.webkit.messageHandlers` 在 `file://` 页面可用；用 `loadHTMLString(data:, baseURL: nil)` 时可能不可用。统一走 `loadFileURL`。

### 2.4 JS 字面量必须安全转义

不要手工拼接 `"..." + method + "..."`：方法名/参数/ID 一律用 `JSONSerialization` 生成 JSON 文本作为 JS 字符串字面量，等价 Kotlin `JSONObject.quote()`，避免引号、换行、注入导致语法错误。

**坑（实测）**：`JSONSerialization.data(withJSONObject: String)` 序列化顶层字符串时必须加 `.fragmentsAllowed`，否则 `NSJSONSerialization` 抛 ObjC 异常，在 Swift 桥接下不会走 Swift 错误处理，而是表现为 malloc guard 内存损坏（模拟器上 "freed pointer was not the last allocation" 崩溃）。`PromiseGateway.parseResult` 对数字/布尔结果做 JSON 序列化时同理。

### 2.5 取消语义（ContinuationBox）

`withCheckedThrowingContinuation` 的续体**必须恰好恢复一次**，否则运行时报告泄漏或双重 resume。所有可能提前终止的路径（调用方取消、超时、WebView 销毁）都需要通过 `ContinuationBox` 安全恢复：

```swift
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    var continuation: CheckedContinuation<T, Error>?

    func resume(with result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
```

**`callJsMethod` 的取消路径：**

```swift
// 正常路径：gateway.register 的 onResult 回调恢复续体
self.gateway.register(id: id, timeoutMs: timeoutMs) { result in
    box.resume(with: result)
}

// setup 后检查：取消先于 setup 的竞态窗口
if Task.isCancelled {
    self.gateway.remove(id: id)
    box.resume(throwing: CancellationError())
}

// onCancel：调用方取消 → 立即恢复续体，pending 移除投递到主线程
} onCancel: {
    Task { @MainActor [weak self] in
        self?.gateway.remove(id: id)  // 移除 pending + 取消超时任务
    }
    box.resume(throwing: CancellationError())
}
```

保证「调用方取消 → 立即 resume + 移除 pending + 取消超时任务」。`resume` 后 box 即置 nil，即使 JS 随后返回结果，gateway 中 pending 也已移除，`finish(id)` 会 no-op。

**`waitForReady` 的取消路径**（原 `awaitReady`）已收进 `PromiseGateway`：

- 就绪先到 → 取消超时任务、恢复续体（成功）
- 超时先到 → 移除就绪监听器、恢复续体（`.timeout`）
- 调用方取消 → 取消超时任务 + 移除监听器 + 恢复续体（`CancellationError()`）

超时任务与监听移除器收拢在 `ReadyWaitBox`（`@unchecked Sendable`）中，`onCancel` 只调用 `box.cancel()`，避免在 `@Sendable` 取消闭包里捕获 MainActor 可变局部变量（否则 Swift 6 编译不过，已用 swiftc 验证）。所有路径都正确清理，无监听器/续体泄漏。

### 2.6 `didFinish` 与 Swift 6 并发

`WKNavigationDelegate` 继承 `NSObjectProtocol`，**Client 必须继承 `NSObject` 才能声明 conformance**（swiftc 实测报 "cannot declare conformance to NSObjectProtocol"）。回调在 Swift 6 中是 nonisolated，不能直接访问 `@MainActor` 状态，采用 `MainActor.assumeIsolated`（Swift 5.9+）声明进入主 actor 上下文（WKWebView 回调始终在主线程，该假设安全）：

- 在 `assumeIsolated` 闭包内可直接访问 `config`、`self` 等 `@MainActor` 状态。
- 使用 completion-handler 版 `evaluateJavaScript(_:completionHandler:)` 替代 async 版本，避免在 nonisolated 上下文中产生 async 调用。错误静默吞掉，与 Kotlin `try-catch` 行为一致。
- `decidePolicyFor` 的 decisionHandler 在新 SDK 中是 `@escaping @MainActor @Sendable`，且 `navigationAction.request` 是 MainActor 隔离属性：签名需写全 `@MainActor @Sendable`，函数体用 `MainActor.assumeIsolated` 包裹后再读取 URL 与调用 decisionHandler（swiftc 实测验证）。
- 兜底就绪脚本通过适配层转发 `onBridgeReady`，与 `wallet-bridge.js` 主动通知形成双重就绪机制。

### 2.7 大体积 vendor 库

`did-0.3.2.min.js` 约 9.6 MB。SPM 用 `.copy` 打进 bundle；若对包体积敏感，可只打包当前需要的 bridge 变体，或对 vendor 库做裁剪/拆分（需回归验证）。

### 2.8 ATS

DID 桥运行时会访问 `https://wodecards.wh.jccdex.cn:8550`，宿主 App 需配置 `NSAllowsArbitraryLoadsInWebContent` 或 host 例外（见 03 章）。

### 2.9 多次 start / destroy 后重建

`start()` 幂等（复用已存在 runtime）；`destroy()` 后再次 `callJsMethod` 会重建 WebView 并重新等待就绪——与 Kotlin `callJsMethod_afterDestroy_recreatesWebViewAndResolves` 对齐。

### 2.10 WebView 生命周期与内存

`WKWebView` 不放在视图层级也能执行 JS，但需由 Client 强持有（Kotlin 的 `WeakReference` 在 Swift 里会让 WebView 提前释放）；`destroy()` 及时置 nil 并清理 gateway。

## 3. 测试策略

### 3.1 单测（无需宿主 App）

| Kotlin 测试 | Swift 对应测试 | 断言要点 |
| --- | --- | --- |
| `JsPromiseGatewayTest` | `PromiseGatewayTests` | 就绪监听释放；已就绪立即回调；回调移除；未知 id 忽略；监听异常隔离；reset/clear；移除器 |
| `WebviewBridgeClientTest` | `WebviewBridgeClientTests` | initialize 存配置；未初始化 `callJsMethod`/`start` 抛错；默认配置稳定 |
| `WebviewBridgeEngineTest` | `WebviewBridgeEngineTests` | 门面委托；start/destroy 幂等；默认值；destroy 后重建 |
| `WebviewBridgeClientBehaviorTest` | `WebviewBridgeClientBehaviorTests` | 见 3.2 |

网关与结果解析完全脱离 WebView，直接单测；Client 行为通过注入 `FakeRuntime` 验证。

### 3.2 行为测试（FakeRuntime）

```swift
@MainActor
final class FakeRuntime: WebViewRuntime {
    var loadedURL: URL?
    var recordedScripts: [String] = []
    var onEvaluate: ((String) -> Void)?
    var userContentController = WKUserContentController()
    var navigationDelegate: WKNavigationDelegate?
    var isHidden = false

    func loadBridgeFile(_ url: URL, allowingReadAccessTo directory: URL) {
        loadedURL = url
    }

    func runJavaScript(_ script: String) async throws -> Any? {
        recordedScripts.append(script)
        onEvaluate?(script)
        return nil
    }

    func stopLoading() {}
    func loadBlank() {}
    func teardown() {}
}
```

对应 Kotlin 行为测试逐条迁移：

| Kotlin 行为测试 | Swift 断言 |
| --- | --- |
| `start_initializesWebView_and_loadsBridgeUrl` | factory 被调用一次、loadedURL 正确、resetReady 被调用 |
| `start_twice_reusesExistingWebView` | factory 只调用一次 |
| `start_fromBackgroundDispatcher_initializesWebView` | 后台 Task 调 start 后 runtime 非空 |
| `pageFinished_evaluatesBridgeReadyScript` | 手动触发 `didFinish`，recordedScripts 含 `onBridgeReady` |
| `callJsMethod_returnsResultFromPromiseBridge` | script 含 `PromiseBridge.call`、`"generateMnemonic"`；`onPromiseResult(id, {"result":"ok"})` 后返回 `"ok"` |
| `callJsMethodAs_parsesJsonResult` | Decodable 解析出期望结构 |
| `callJsMethodAs_returnsRawStringWhenRequested` | String 目标原样返回 |
| `callJsMethod_coercesNonStringResultToString` | `123 -> "123"`、对象 -> JSON 文本 |
| `callJsMethod_timesOutWhenBridgeNeverBecomesReady` | 短 readyWait 后抛 `.timeout` |
| `callJsMethod_propagatesWebViewFactoryFailure` | factory 抛错向上传播 |
| `callJsMethod_reportsInvalidResponseFormat` | `{"status":"ok"}` → `.invalidResponseFormat` |
| `callJsMethod_reportsMalformedJsonResponse` | `not-json` → `.malformedJSON` |
| `callJsMethod_reportsErrorResponse` | `{"error":"boom"}` → `.jsError("boom")` |
| `callJsMethod_afterDestroy_recreatesWebViewAndResolves` | destroy 后 factory 调用次数 +1，再次调用可完成 |
| `destroy_clearsWebViewAndGateway` | handler 移除、pending 清空、isReady=false |

### 3.3 集成测试（真实 WKWebView）

单测覆盖不了真实 `WKWebView` 的 JS 执行。当前实现把真实 WebView 集成测试直接放进 SPM 测试 target：

- `WebviewBridgeClientBehaviorTests`：每个用例独立创建真实 `WebviewBridgeClient`，走生产路径的 `wallet-bridge.html` JS，验证 `generateMnemonic` / `validateMnemonic` / `noSuchMethod` 错误等完整链路；
- `WebviewBridgeEngineTests`：`callMethods_roundTripThroughRealWebView` 等用例覆盖引擎门面 + 真实 WebView。

真实 WebView 用例只在 iOS 模拟器上运行（`WKWebView` 在无宿主 App 的 SPM 测试进程内可用），运行命令与策略：

```bash
# macOS：单测/行为测试（FakeRuntime）
bundle exec fastlane macos_test

# iOS 模拟器：真实 WKWebView 集成测试（默认最新运行时）
bundle exec fastlane ios_test

# 指定 iOS 主版本与机型（与 CI 一致）
bundle exec fastlane ios_test "device_name:iPhone 16" device_os:18
```

稳定性策略：`ios_test` 会自动预热模拟器（`simctl bootstatus -b`）、串行执行（`-parallel-testing-enabled NO`），并对失败用例自动重试一次（`-retry-tests-on-failure` + `-test-iterations 2`），以吸收慢 runner 上 WebContent 冷启动造成的偶发超时。

> 双变体说明：`wallet-bridge.html` 走脚本主动通知就绪，`did-bridge.html` 走 `didFinish` 兜底；两套资源均已随 target 打包。

## 4. 实施清单

- [ ] 在 `Package.swift` 注册 `SwiftWebviewBridge` target 与 `Resources/bridge` 资源
- [ ] 实现 `WebviewBridgeError` / `WebviewBridgeConfig` / `BridgeScripts`
- [ ] 实现 `PromiseGateway`（回调表、就绪监听、结果解析）
- [ ] 实现 `WebViewRuntime` 协议与 `WKWebView` conformance
- [ ] 实现 `BridgeMessageHandler` 与 delegate 转发
- [ ] 实现 `WebviewBridgeClient`（initialize/start/callJsMethod/callJsMethodAs/destroy）
- [ ] 实现 `WebviewBridgeEngine` 单例门面与 internal 测试钩子
- [ ] 拷贝 Kotlin assets 到 `Resources/bridge`
- [ ] 单测：gateway、解析、client 行为（FakeRuntime）、engine
- [ ] 集成测试：真实 WKWebView + 双 bridge 变体
- [ ] 宿主 App ATS 配置说明与示例
- [ ] 更新仓库 README 快速接入
