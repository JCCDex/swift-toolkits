# 01 · Kotlin 版架构解析

## 1. 模块定位

`webview-bridge` 是 `kotlin-toolkits` 的底层模块：初始化一个**不可见的隐藏 WebView**，加载打包在 assets 中的桥接页面，提供「Native 调用 JS 方法并等待 Promise 结果」的能力。`did`、`wallet` 等 SDK 的 Android 默认实现构建在其之上，不直接暴露给上层业务。

## 2. 文件清单与职责

| 文件 | 角色 |
| --- | --- |
| `WebviewBridgeConfig.kt` | 配置：bridge 页面 URL、JS 接口名、console tag |
| `WebviewBridgeEngine.kt` | 唯一入口（`object` 单例），代理到默认 Client |
| `WebviewBridgeClient.kt` | 核心实现：WebView 生命周期、调用编排、超时、销毁 |
| `JsPromiseGateway.kt` | Promise 网关：回调表、就绪监听、JS 注入接口 |
| `assets/bridge.html`（did/wallet 两个变体） | 隐藏页入口，按顺序加载 vendor 库与 bridge JS |
| `assets/*-bridge.js` | JS 侧 `PromiseBridge`：方法注册表 + 统一回调 |
| `assets/*.min.js` | vendor 库（jcc-wallet / did / jingtum-lib / eth-sig-util / ethereumjs-tx） |

## 3. 关键类逐个拆解

### 3.1 WebviewBridgeConfig

```kotlin
data class WebviewBridgeConfig(
    val bridgeUrl: String = androidAssetUrl("bridge.html"), // file:///android_asset/bridge.html
    val jsInterfaceName: String = "JSBridge",
    val consoleTag: String = "WebViewConsole"
)
```

默认值有测试锁定（`config_defaults_areStable`），移植时必须保持等价默认值。

### 3.2 WebviewBridgeEngine

```kotlin
object WebviewBridgeEngine {
    private val defaultClient = WebviewBridgeClient(JsPromiseGateway)

    fun initialize(context: Context, config: WebviewBridgeConfig = WebviewBridgeConfig())
    fun start()
    suspend fun callJsMethod(method: String, params: JSONObject? = null,
        timeoutMs: Long = 30_000L, readyWaitMs: Long = 15_000L): String
    suspend fun <T> callJsMethodAs(method: String, params: JSONObject? = null,
        clazz: Class<T>, timeoutMs: Long = 30_000L, readyWaitMs: Long = 15_000L): T
    fun destroy()
}
```

纯门面：无状态，全部委托给内部单例 Client。

### 3.3 WebviewBridgeClient

职责与要点：

1. **initialize(context, config)**：只保存 `applicationContext` 与配置，不创建 WebView（延迟到 `start()`/首次调用）。
2. **start()**：非主线程调用时 `Handler.post` 到主线程；重复调用复用已有 WebView（`start_twice_reusesExistingWebView`）。
   - 设置：`javaScriptEnabled`、`domStorageEnabled`、`allowFileAccess = false`、`LOAD_NO_CACHE`。
   - `addJavascriptInterface(gateway, config.jsInterfaceName)`。
   - `WebViewClient.shouldOverrideUrlLoading`：**只允许 `file:///android_asset/`，其余 URL 一律拦截**。
   - `WebViewClient.onPageFinished`：执行 `if (window.JSBridge && window.JSBridge.onBridgeReady) { window.JSBridge.onBridgeReady(); }` 作为就绪兜底（did-bridge.js 自身不主动通知）。
   - `WebChromeClient.onConsoleMessage`：默认吞掉（debug 开关为 false）。
   - `visibility = INVISIBLE` 后 `loadUrl(config.bridgeUrl)`。
3. **callJsMethod()**（核心链路）：
   - 未初始化直接抛 `IllegalStateException`。
   - `ensureWebViewStarted()`（非主线程会切主线程创建）。
   - `awaitReady(readyWaitMs.coerceAtMost(timeoutMs))`。
   - `withTimeout(timeoutMs) + suspendCancellableCoroutine`：
     - `UUID.randomUUID()` 生成 id；
     - 在 `gateway.callbackMap[id]` 注册回调：解析 `{error}` / `{result}`，字符串原样返回，其它类型 `toString()`（数字 123 → `"123"`，对象 → JSON 文本）；
     - 主线程执行 `PromiseBridge.call("method", {...}, "id");`；
     - `invokeOnCancellation` 移除回调。
4. **callJsMethodAs()**：String 直接返回；其它类型用 Gson 反序列化。
5. **destroy()**：主线程依次 `removeJavascriptInterface` → `loadUrl("about:blank")` → `stopLoading` → `removeAllViews` → `destroy`，最后 `gateway.clearAll()`；**destroy 后再次调用会自动重建 WebView**（`callJsMethod_afterDestroy_recreatesWebViewAndResolves`）。

### 3.4 JsPromiseGateway / PromiseGatewayImpl

```kotlin
internal interface IPromiseGateway {
    val callbackMap: ConcurrentHashMap<String, (String) -> Unit>
    fun onPromiseResult(id: String, resultJson: String)   // @JavascriptInterface
    fun onBridgeReady()                                   // @JavascriptInterface
    fun isReady(): Boolean
    fun addReadyListener(listener: () -> Unit): () -> Unit
    fun resetReady()
    fun clearAll()
}
```

实现要点：

- `callbackMap` 用 `ConcurrentHashMap`（JS 回调线程不确定）；`readyListeners` 用 `CopyOnWriteArrayList`。
- `onPromiseResult`：`remove(id)?.invoke(resultJson)`，**未知 id 静默忽略**。
- `onBridgeReady`：置 ready、逐个执行监听并清空；**单个监听抛异常不影响其余监听**。
- `addReadyListener`：已就绪则立即回调并返回空移除器；否则登记并返回可移除函数。
- `clearAll`：清空回调、监听、ready。
- `JsPromiseGateway` 是暴露给 `addJavascriptInterface` 的 object 单例，内部委托 `PromiseGatewayImpl`。

## 4. 生命周期与调用流程

```text
initialize(context, config)
   │
start() ──► resetReady() → 创建隐藏 WebView → 注入 JSBridge → loadUrl(bridge.html)
   │                                          │
   │        JS 加载完成：bridge.js 执行完毕（wallet 变体主动 onBridgeReady）
   │        onPageFinished 兜底：检测 window.JSBridge.onBridgeReady 并调用
   ▼
callJsMethod(method, params, id)
   │  ensureWebViewStarted → awaitReady(≤ readyWaitMs)
   │  evaluateJavascript: PromiseBridge.call(method, params, id)
   ▼
JS: methods[method](params) ──► onPromiseResult(id, JSON.stringify({result}))
   │                                                     或 {error: "..."}
   ▼
gateway 命中 id → 恢复挂起协程 → 返回字符串 / 抛错 / 超时
```

## 5. 资产与 JS 侧约定

- `wallet-bridge.html` 加载 `jcc-wallet / jingtum-lib / eth-sig-util / ethereumjs-tx` 与 `wallet-bridge.js`；`did-bridge.html` 加载 `jcc-wallet / did` 与 `did-bridge.js`。
- 两个 bridge JS 都定义 `global.PromiseBridge.call(method, params, id)`：校验方法名 → 查 `methods` 表 → `await fn(params)` → `window.JSBridge.onPromiseResult(id, JSON.stringify({ result }))`；异常时回 `{ error: message }`。
- `wallet-bridge.js` 在脚本末尾调用 `onBridgeReady()`；`did-bridge.js` 不调用，依赖 `onPageFinished` 兜底——Swift 移植必须保留双重就绪机制。

## 6. 测试基线（移植验收对照）

| 测试文件 | 覆盖点 |
| --- | --- |
| `JsPromiseGatewayTest` | ready 监听释放、已就绪立即回调、回调移除、未知 id 忽略、监听异常隔离、reset/clear、移除器 |
| `WebviewBridgeClientTest` | initialize 存配置、未初始化抛错、默认配置、start 未初始化抛错 |
| `WebviewBridgeEngineTest` | 门面委托、start/destroy 幂等、默认值稳定、destroy 后重建 |
| `WebviewBridgeClientBehaviorTest` | 创建/复用 WebView、后台线程启动、onPageFinished 就绪脚本、调用解析、结果字符串化、超时、工厂异常、非法/畸形响应、error 响应、destroy 清理 |

Swift 移植的测试策略见 [04-migration-and-testing.md](04-migration-and-testing.md)。
