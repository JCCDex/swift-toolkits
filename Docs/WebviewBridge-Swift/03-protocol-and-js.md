# 03 · 通信协议与 JS 桥接层

## 1. 协议总览（与 Kotlin 一致）

协议分三层，Swift 只替换最底层的「通道」：

```text
┌──────────┐   PromiseBridge.call(method, params, id)   ┌──────────────┐
│  Native  │ ──────────────────────────────────────────► │  Bridge JS   │
│ (Swift)  │ ◄────────────────────────────────────────── │  (methods表) │
└──────────┘   onPromiseResult(id, JSON.stringify(       └──────────────┘
                    {result} 或 {error: "..."}))
```

### 1.1 Native → JS

```js
PromiseBridge.call("generateMnemonic", {"length":128}, "5f7a9c1e-...");
```

- `method`：字符串字面量，必须安全转义（用 JSON 编码生成）。
- `params`：JSON 对象文本，无参数时为 `null`。
- `id`：字符串字面量，每次调用唯一的 UUID。

### 1.2 JS → Native

成功：

```js
window.JSBridge.onPromiseResult(id, JSON.stringify({ result: { address: "0x..." } }));
```

失败：

```js
window.JSBridge.onPromiseResult(id, JSON.stringify({ error: "Private key is required" }));
```

### 1.3 就绪通知

```js
window.JSBridge.onBridgeReady();
```

Kotlin 的双重就绪机制在 Swift 中必须保留：

1. `wallet-bridge.js` 在脚本末尾主动调用（`did-bridge.js` 不调用）；
2. `WKNavigationDelegate.didFinish` 兜底：检测 `window.<jsInterfaceName>.onBridgeReady` 并调用。

## 2. Swift 侧通道替换

### 2.1 为什么需要适配脚本

Kotlin 资产里的 `*-bridge.js` 写死了 `window.JSBridge.onPromiseResult(...)` 与 `window.JSBridge.onBridgeReady()`。iOS 没有 `addJavascriptInterface`，无法凭空注入 `window.JSBridge` 原生对象，所以在**页面任何脚本执行之前**注入一个适配脚本，模拟出同样的对象，并转发到 WebKit 消息通道：

```js
(function () {
  'use strict';
  window.JSBridge = {
    onPromiseResult: function (id, resultJson) {
      window.webkit.messageHandlers.onPromiseResult.postMessage({
        id: id,
        resultJson: resultJson
      });
    },
    onBridgeReady: function () {
      window.webkit.messageHandlers.onBridgeReady.postMessage(null);
    }
  };
})();
```

对应 Swift 生成器（`BridgeScripts`）：

```swift
enum BridgeScripts {
    static func adapter(interfaceName: String) -> String {
        """
        (function () {
          'use strict';
          window.\(interfaceName) = {
            onPromiseResult: function (id, resultJson) {
              window.webkit.messageHandlers.onPromiseResult.postMessage({
                id: id,
                resultJson: resultJson
              });
            },
            onBridgeReady: function () {
              window.webkit.messageHandlers.onBridgeReady.postMessage(null);
            }
          };
        })();
        """
    }

    /// 可选：把 console 转发到原生（对应 Kotlin 里默认关闭的 onConsoleMessage）
    static let consoleForwarding = """
    (function () {
      var levels = ['log', 'info', 'warn', 'error', 'debug'];
      for (var i = 0; i < levels.length; i++) {
        (function (level) {
          var original = console[level];
          console[level] = function () {
            try {
              window.webkit.messageHandlers.onConsole.postMessage({
                level: level,
                message: Array.prototype.slice.call(arguments).map(String).join(' ')
              });
            } catch (e) {}
            if (original) original.apply(console, arguments);
          };
        })(levels[i]);
      }
    })();
    """
}
```

### 2.2 消息 Handler 命名约定

| Handler 名 | 载荷 | 触发方 |
| --- | --- | --- |
| `onPromiseResult` | `{ id: String, resultJson: String }` | 适配脚本转发 JS 结果 |
| `onBridgeReady` | `null` | 适配脚本转发就绪通知 |
| `onConsole`（可选） | `{ level: String, message: String }` | console 转发脚本 → `WKScriptMessageHandler` → `BridgeMessageHandlerDelegate.onConsole(level:message:)` → `NSLog`（仅当 `allowsConsoleForwarding = true`） |

`jsInterfaceName`（默认 `JSBridge`）只决定 `window` 上的对象名，与 Handler 名解耦；这样上层业务看到的 JS 对象名和 Kotlin 完全一致。

### 2.3 注入顺序

```text
WKWebView 创建
  └─ userContentController
      ├─ add(handler, name: "onPromiseResult")
      ├─ add(handler, name: "onBridgeReady")
      ├─ addUserScript(适配脚本, .atDocumentStart)     // 最先执行
      ├─ addUserScript(consoleForwarding, .atDocumentStart)  // 可选
loadFileURL(bridge.html, allowingReadAccessTo: bridge 目录)
  └─ HTML 顺序：vendor 库 → bridge.js →（脚本末尾/onPageFinished）onBridgeReady
```

## 3. 调用时序（完整）

```text
App                                 Client                        WKWebView            Bridge JS
 │  callJsMethod("generateMnemonic") │                              │                   │
 │ ────────────────────────────────► │  start()（懒创建，仅首次）     │                   │
 │                                   │ ───────────────────────────► │ loadFileURL       │
 │                                   │                              │                   │ 执行 bridge.js
 │                                   │                              │ onBridgeReady ◄───┘
 │                                   │ ◄── didFinish 兜底（可选路径） │
 │                                   │  gateway.isReady = true      │                   │
 │                                   │  waitForReady 返回            │                   │
 │                                   │  register(id, timeoutTask)   │                   │
 │                                   │ ── PromiseBridge.call(...) ─►│ ──► 执行方法      │
 │                                   │                              │ onPromiseResult ─►│
 │                                   │ ◄─ 命中 pending，取消超时任务 │                   │
 │ ◄── 返回结果字符串 / 抛错 / 超时   │                              │                   │
```

## 4. 资源打包与加载

### 4.1 资产清单（与 Kotlin assets 一一对应）

| Kotlin assets | Swift Resources/bridge | 说明 |
| --- | --- | --- |
| `wallet-bridge.html` / `did-bridge.html` | 同名拷贝 | 隐藏页入口 |
| `wallet-bridge.js` / `did-bridge.js` | 同名拷贝 | 定义 `PromiseBridge` |
| `jcc-wallet-4.0.8.min.js` | 同名拷贝 | vendor |
| `jingtum-lib.min.js` | 同名拷贝 | vendor |
| `eth-sig-util.min.js` | 同名拷贝 | vendor |
| `ethereumjs-tx-5.4.0.min.js` | 同名拷贝 | vendor |
| `did-0.3.2.min.js` | 同名拷贝 | vendor（约 9.6 MB，注意包体积） |

### 4.2 加载方式

必须用 `loadFileURL(_:allowingReadAccessTo:)` 加载并授予**桥接目录**的读权限，才能让 HTML 里的相对 `<script src>` 正常解析：

```swift
let bridgeURL =
    bundle.url(forResource: "wallet-bridge", withExtension: "html")
    ?? bundle.url(forResource: "wallet-bridge", withExtension: "html", subdirectory: "bridge")!
webView.loadFileURL(bridgeURL, allowingReadAccessTo: bridgeURL.deletingLastPathComponent())
```

避免用 `loadHTMLString(_:baseURL:)`：baseURL 为 nil 时 `window.webkit.messageHandlers` 可能不可用，且相对资源解析行为不稳定。

### 4.3 WebView 配置差异

与 Kotlin 参考实现的关键配置对比：

| 配置项 | Kotlin | Swift | 说明 |
| --- | --- | --- | --- |
| JS 启用 | `javaScriptEnabled = true` | `configuration.preferences.javaScriptEnabled = true` | 等价 |
| DOM Storage | `domStorageEnabled = true` | 默认启用（`WKWebView`） | iOS WKWebView 默认启用 DOM Storage，无需显式配置。使用 `.nonPersistent()` 数据存储时 localStorage/sessionStorage 仅在内存中存活，行为与 Kotlin `LOAD_NO_CACHE` 一致 |
| 文件访问 | `allowFileAccess = false` | `loadFileURL(_:allowingReadAccessTo:)` 仅授权桥接目录 | iOS 采用白名单方式天然更安全 |
| 缓存 | `LOAD_NO_CACHE` | `websiteDataStore = .nonPersistent()` | 不持久化任何 Web 数据，效果更强 |

### 4.4 ATS（App Transport Security）

桥接页面本身是 `file://` 本地加载，不触发 ATS；但 `did-bridge.js` 里的 IPFS 客户端会访问 `https://wodecards.wh.jccdex.cn:8550`。宿主 App 需要在 `Info.plist` 放行：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
</dict>
```

或针对该 host 配置例外。wallet 桥不依赖外部网络（纯本地签名），通常无需放行。

## 5. 错误与超时语义

| 场景 | Kotlin 行为 | Swift 行为 |
| --- | --- | --- |
| 未 initialize | `IllegalStateException` | `WebviewBridgeError.notInitialized` |
| JS 返回 `{error}` | `Exception(message)` | `WebviewBridgeError.jsError(message)` |
| 响应缺 `result`/`error` | `Exception("Invalid response format")` | `WebviewBridgeError.invalidResponseFormat` |
| 响应非法 JSON | `JSONException` | `WebviewBridgeError.malformedJSON` |
| 就绪等待超时（readyWaitMs） | `TimeoutCancellationException` | `WebviewBridgeError.timeout` |
| 调用超时（timeoutMs） | `TimeoutCancellationException` | `WebviewBridgeError.timeout` |
| JS 执行失败（evaluate 异常） | 原异常上抛 | 原 NSError 上抛 |

超时边界：`readyWaitMs.coerceAtMost(timeoutMs)`（Swift：`min(readyWaitMs, timeoutMs)`）。

### 5.1 并发安全与竞态处理

由于 JS 回调 (`onPromiseResult`) 和超时任务 (`Task.sleep`) 可能同时触发，`PromiseGateway.finish(id:result:)` 采用**先到先赢**策略：

- `guard let call = pending.removeValue(forKey: id) else { return }` — 后到者的 `removeValue` 返回 nil，静默退出。
- 超时 Task 和 JS 回调都在 `@MainActor` 上串行执行，天然互斥。
- 调用方取消（`onCancel`）立即 resume 续体（`CancellationError`），pending 移除通过 `Task { @MainActor }` 投递；`ContinuationBox` 恢复后即置 nil，即使 JS 随后响应，`finish(id)` 也只走 no-op 分支，不会二次 resume。
- 续体 body 在 setup 完成后检查 `Task.isCancelled`，关闭「取消先于 setup」的竞态窗口（否则续体可能无人恢复，只能等网关超时兜底）。

`waitForReady(timeoutMs:)` 同理：`ReadyWaitBox`（续体 + 超时任务 + 监听移除器收拢在一个 `@unchecked Sendable` 容器里）保证三路径（就绪/超时/取消）恰好一个恢复续体，且取消时移除就绪监听、取消超时任务。详见 [02-swift-design.md](02-swift-design.md) 3.4 节 PromiseGateway 实现。
