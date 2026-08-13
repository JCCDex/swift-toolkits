# 03 · 通信协议与 JS

## 1. 消息格式（JS → Native）

DApp 侧统一经 `window._tw_.postMessage(json)`（Android）或 reply 变体（iOS）发送：

```json
{
  "name": "eth_sendTransaction",
  "network": "eth",
  "id": "1",
  "nonce": "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx",
  "params": [ { "from": "0x...", "to": "0x...", "value": "0x0" } ]
}
```

- `name`：RPC 方法名（见 `DAppMethod`）。
- `network`：`swtc` / `eth` / `ccdao`（由方法前缀推导）。
- `nonce`：`randomUUID()`，用于匹配响应；缺省回落 `id`。
- `params`：数组，缺省为 `[]`。

## 2. 响应格式（Native → JS）

```json
{ "nonce": "...", "result": ... }
{ "nonce": "...", "error": { "code": 4001, "message": "User rejected the requestAccounts request" } }
```

JS 侧 `requestQueue[nonce]` 匹配，先到先删；`error` 存在则 reject，否则 resolve `result`。

> **对 Kotlin 的显式改进——超时兜底**：Kotlin 在 native 无法回传（崩溃、非法请求只打日志）时，`requestQueue` 条目会永久悬挂，DApp Promise 不 settle。Swift 版为每个请求增加 60s 超时，超时自动以 `{error:{code:-1,message:"Native bridge timeout"}}` settle。为避免 timer 泄漏，队列条目存 `{ callback, timer }`，`settleRequest` 时一并 `clearTimeout`：
>
> ```js
> // sendToNative 内：登记请求 + 启动 60s 超时
> requestQueue[nonce] = {
>   callback: callback,
>   timer: setTimeout(function () {
>     settleRequest(nonce, { error: { code: -1, message: 'Native bridge timeout' } });
>   }, 60000)
> };
>
> // settleRequest：settle 时清 timer，防止正常回包后 timer 残留
> function settleRequest(nonce, response) {
>   const entry = requestQueue[nonce];
>   if (!entry) return;
>   delete requestQueue[nonce];
>   clearTimeout(entry.timer);
>   entry.callback(response);
> }
> ```
>
> 同时约定：native 所有回复路径（含校验/解析失败）统一带 `nonce` 回传 `{nonce, result|error}` 字典（`[String: Any]`，WebKit 自动序列化）；确实无法取得 nonce 的极端情况由超时兜底。

## 3. 传输通道

### 3.1 Android（Kotlin 现状，C-03）

`WebMessagePort` 握手：native `createWebMessageChannel()` → 把 JS 端口经 `postWebMessage(HANDSHAKE, ports)` 交给页面 → provider JS 的 `window.addEventListener('message')` 收端口并 `acceptNativePort`。响应不再暴露 `window.ccdao.sendResponse`，页面脚本无法伪造 RPC 完成。

### 3.2 iOS（Swift 设计）

`WKWebView` 无 WebMessagePort。Swift 版等价通道：

- JS 侧：`window.webkit.messageHandlers._tw_.postMessage(json)`（legacy `WKScriptMessageHandler`，无 reply 参数）。
- Native 侧：`userContentController(_:didReceive:)` 路由完成后，经 `evaluateJavaScript` 调用 `window._ccdaoSettle(nonce, payloadJson)` 回传。
- **为什么不用 `WKScriptMessageHandlerWithReply`**：实测该 reply 通道在裸测试进程（macOS/iOS 模拟器）中消息能进（`didReceive` 被调用）但回复不送达 JS；legacy handler + evaluateJavaScript 与 SwiftWebviewBridge 同款、已验证可用。页面内伪造 `_ccdaoSettle` 只能 settle 自身请求（nonce 只有发起方知道），与 WithReply 安全性等价。
- 由于 provider JS 的 `requestQueue` 是 IIFE 私有闭包，Swift 直接复用 Kotlin JS 无法 settle 响应；因此 Swift 版携带 **`ccdao-eip1193-provider-ios.js`**：与 Kotlin 版仅 `sendToNative` 的传输段不同，并新增 `window._ccdaoSettle` 作为 native 回传入口：

```js
// Kotlin 版（Android）：window._tw_.postMessage(json)，响应经端口
if (window._tw_ && window._tw_.postMessage) {
  window._tw_.postMessage(message);
}

// iOS 变体：legacy postMessage；native 经 evaluateJavaScript 调 window._ccdaoSettle 回传
if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers._tw_) {
  window.webkit.messageHandlers._tw_.postMessage(message);
} else {
  console.error('[CCDAO EIP-1193] _tw_ not available');
  // 对 Kotlin 的显式偏离：Kotlin 回字符串 error；这里统一为 {code,message} 结构，
  // 让 DApp 侧只处理一种 error 形态（见 04 章坑 #13）。
  settleRequest(nonce, { error: { code: -1, message: 'Bridge not available' } });
}

// native → JS 响应投递入口（与 sendToNative 同闭包，可访问私有 requestQueue）
window._ccdaoSettle = function (nonce, payloadJson) {
  var msg = JSON.parse(payloadJson);
  if (!msg || msg.nonce !== nonce) return;
  if (Object.prototype.hasOwnProperty.call(msg, 'error')) {
    settleRequest(msg.nonce, { error: msg.error });
  } else {
    settleRequest(msg.nonce, { result: msg.result });
  }
};
```

其余逻辑（状态、事件、拦截、EIP-6963、二进制参数归一化）与 Kotlin 版保持一致，确保行为契约不漂移。

> **回复形态**：native 统一以 JSON 字符串回传（`_ccdaoSettle(nonce, payloadJson)` 内 `JSON.parse`），与 Kotlin wire 格式严格一致，也便于统一日志；不再区分字典/字符串双形态。

## 4. provider JS 能力

`ccdao-eip1193-provider.js` 注入后提供：

- `window.ethereum` / `window.eth`：EIP-1193 provider（`request` / `on` / `removeListener` / `removeAllListeners` / `emit`）。
- `window.ccdao`：CCDAO 扩展 provider，与 `window.ethereum` 共享 `state.listeners` 与 `requestQueue`。
- 本地拦截：`eth_chainId` / `eth_accounts` 直接读状态；`eth_requestAccounts` 走 native 并写回 `state.accounts`。
- 全局推送函数：
  - `_updateSelectedAddress(address)` → `accountsChanged`（地址未变不触发）
  - `_updateSwtcSelectedAddress(address)` → `swtcAccountsChanged`
  - `_updateChainId(chainIdHex, rpcUrl)` → `chainChanged`
- `ipfs_personalSign` 二进制参数归一化：`ArrayBuffer` / TypedArray / 数组 → 普通字节数组再传给原生。
- EIP-6963：`eip6963:announceProvider` 广播（5s 周期 + 响应 `eip6963:requestProvider`）；宿主可经 `loadEip6963IconOverrideJs` 覆盖真实钱包图标。

## 5. URL / Origin 安全

### 5.1 isSafeUrl

```regex
^(https?)://[a-zA-Z0-9][-a-zA-Z0-9]{0,62}(\.[a-zA-Z0-9][-a-zA-Z0-9]{0,62})+\.?(:[0-9]{1,5})?(/.*)?$
```

拒绝 `file://`、`javascript:` 等。Kotlin 还叠加 `android.util.Patterns.WEB_URL`；Swift 用相同正则即可（iOS 无 `Patterns` 等价物，正则覆盖已足够）。

> 平台差异（已对照 AOSP `Patterns.java` 核实）：Kotlin 的 `isSafeUrl = 严格正则 || Patterns.WEB_URL`，而 `WEB_URL` 比严格正则更宽：
>
> 1. `PROTOCOL = (?i:http|https|rtsp|ftp)://` —— Kotlin 会放行 **`rtsp://` / `ftp://`**；Swift 只有严格正则，**拒绝**。
> 2. `WEB_URL` 支持 **userinfo**（`https://user@host/...`）与 **IDN/unicode 域名**（IRI_LABEL + UCS_CHAR）；Swift ASCII 正则拒绝。
> 3. `localhost` 这类**无点单标签主机两边都拒**（`WEB_URL` 的 `HOST_NAME` 要求 `(label\.)+ TLD`），所以本地调试单标签主机不是 Kotlin/Swift 差异——宿主若需要，须自行扩展 `isSafeUrl`。
>
> 结论：Swift 的 URL 校验比 Kotlin 更严格（更安全），属预期行为；如宿主希望对齐 Kotlin 的放行面，可显式叠加 `WEB_URL` 等价规则并标注偏离。

### 5.2 WebOrigin.normalize

- 仅接受 http/https + 非空 host；host/scheme 小写。
- 非默认端口保留：`https://dapp.example.com:8443`；默认端口（80/443）省略。
- 非法输入返回 `nil`。
- 哨兵 `WALLET_INTERNAL = "wallet_internal"`：原生 NFT/签名内部取密钥用，宿主不得将其当作可授权 web origin（M-18）。

## 6. ATS 说明

DApp 页面可能是任意 https 站点；若需加载 http 页面或 WebView 内访问非 TLS 资源，宿主需配置 `NSAppTransportSecurity` 例外（`NSAllowsArbitraryLoadsInWebContent` 或按 domain 例外），与 Kotlin 侧 manifest 网络权限语义对应。
