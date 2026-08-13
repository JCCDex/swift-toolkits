# 04 · 迁移对照、实现注意点与测试策略

## 1. 迁移对照表

| Kotlin | Swift | 说明 |
| --- | --- | --- |
| `DAppConnectSdk` object | `enum DAppConnectSdk` | 静态工具入口；无 Android Context/Resources |
| `WebAppInterface` | `@MainActor WebAppInterface` | `@JavascriptInterface` → `WKScriptMessageHandlerWithReply` |
| `WebAppInterfaceWithWebView` | 并入 `WebAppInterface` | 无需子类，WebView 由宿主持有 |
| `NativeResponseChannel` | `NativeResponseChannel`（payload 序列化） | 端口通道 → reply 回调 |
| `WebOrigin` | `enum WebOrigin` | normalize + `walletInternal` |
| `IEthMiddleware` / `EthMiddleware` | `EthMiddlewareProtocol` / `EthMiddleware` | `suspend` → `async throws` |
| `ISwtcMiddleware` / `SwtcMiddleware` | `SwtcMiddlewareProtocol` / `SwtcMiddleware` | 同上 |
| `RequestAccountsCallback` | `RequestAccountsCallback` | `suspend (String) -> Boolean` → `async (String) -> Bool` |
| `AccountProvider` | `AccountProvider` | `Flow` → `AsyncStream` |
| `SecretProvider` | `SecretProvider` | 同上 |
| `NodeProvider` | `NodeProvider` | 同上 |
| `ChainProvider` / `ChainConfigProvider` | `ChainProvider` / `ChainConfigProvider` | 同上 |
| `NftProvider` + NFT 数据类 | `NftProvider` + `EvmNftResult` 等 | Codable |
| `CachingSecretProvider` | `actor CachingSecretProvider` | Mutex + 定时清理 → actor 串行化 |
| `DAppMethod` enum | `DAppMethod` enum | rawValue = 方法名 |
| `JsonRpcResponse` / 异常 | `DAppConnectError` | 错误码 4001/4902/-1（4100/-32603 为 Kotlin 死代码） |
| `WalletSdk` 调用 | `WalletSigning` 协议 | 宿主接线（SwiftVault 供钥） |
| `DidSdk` 调用 | `DidSDK` 协议 | 宿主接线 |
| `ChainType` / `WalletAccount` | `ChainType` / `WalletAccount` | 从 core 模型平移到模块内 |

## 2. 实现注意点 / 坑

1. **无 `addJavascriptInterface`**：必须注入适配脚本把 `window._tw_.postMessage` 接到 `window.webkit.messageHandlers._tw_.postMessage(json, reply)`；命名 handler 为 `_tw_` 保持 DApp 侧零改动。
2. **reply 只能一次且尽可能带 nonce**：`WKScriptMessageHandlerWithReply` 的 `replyHandler` 必须恰好调用一次；所有提前返回路径（校验/解析失败）都要回传 `{nonce, error:{code,message}}` 的 payload 字典，不能只回裸错误串——否则 JS `requestQueue` 无法 settle；确实无法取得 nonce 时（body 非字符串）靠 JS 侧超时兜底（Kotlin 对非法请求只打日志不回复，属继承缺陷，Swift 统一修正，见 03 章）。
3. **主线程约束**：`WKScriptMessageHandlerWithReply` 回调在主线程；`WebAppInterface` 标 `@MainActor`，路由内 `Task { @MainActor }` 保证回复仍回主线程。
4. **私有 requestQueue 不可注入 settle**：Swift 必须使用 provider JS 的 iOS 传输变体，不能只靠注入补丁（闭包外部无法访问 queue）。
5. **JSON 处理**：`params` 是异构数组，Swift 用 `[Any]`/`JSONSerialization` 解析而非强类型 Decodable；响应序列化需区分 String/Number/Bool/Object/Array/Null，避免 `0x123` 被 JS 解析成数字。
6. **错误码映射**：`UserRejectedException→4001`、`ChainNotSupportedException→4902`，其余所有异常在 `WebAppInterfaceWithWebView.sendErrorResponse` 里统一回传 `code = -1`。注意 Kotlin 虽定义了 `UnauthorizedException`(4100) 与 `TransactionException`(-32603)，但路由层从未抛出/捕获，属于死代码；Swift 侧对齐真实行为时通用错误应为 `-1`，若有意改为 `-32603` 需作为对 Kotlin 的显式偏离标注。
7. **不落库敏感数据**：日志只允许 method/network/错误码，禁止打印 tx、签名、消息、密文、地址列表。
8. **HD 根过滤**：EVM/SWTC 的 requestAccounts 都必须排除 `isHD && parentId == nil`（对应 Kotlin 中间件 `!(it.isHD && it.parentId == null)`，不检查 `path`）。注意与 core 模型 `WalletAccount.isRootHD()`（`isHD && path?.isRoot() == true && parentId == null`）区分：中间件过滤只用 `parentId`，不用 `path`。
9. **并发弹窗**：`CachingSecretProvider` 的私钥/秘钥锁要独立，同地址并发请求只委托一次。
10. **ATS**：WebView 加载 http 页面需宿主配置例外；SDK 不内置。
11. **默认初始链**：`createEthMiddleware` 的 `initialChain` 默认 `ChainType.BSC`（Kotlin 同），实现时别漏默认值。
12. **requestQueue 超时兜底（对 Kotlin 的显式改进）**：Swift 的 provider JS 为每个请求加 60s 超时自动 reject；队列条目存 `{callback, timer}`，`settleRequest` 时 `clearTimeout` 防止 timer 泄漏；测试需覆盖「native 不回传时 Promise 最终 reject 而非挂起」。
13. **bridge 不可用错误结构（对 Kotlin 的显式偏离）**：`_tw_` 缺失时回 `{error:{code:-1,message:'Bridge not available'}}`；Kotlin 回的是字符串 `'Bridge not available'`。统一为 `{code,message}` 后 DApp 侧只需处理一种 error 形态；测试需断言该错误码为 -1。

## 3. 测试策略

### 3.1 纯单测（无需 WebView）

| 目标 | 用例 |
| --- | --- |
| `DAppMethod` | 全部方法名 ↔ 枚举映射；未知方法 → `.unknown` |
| `WebOrigin` | normalize 默认端口省略、非 http(s) 返回 nil、host 小写；`walletInternal` 哨兵 |
| `DAppConnectSdk.isSafeUrl` | https/http/端口/路径/query/合法域名；拒绝 `file://`、`javascript:`、空串 |
| `NativeResponseChannel` | success/error payload 序列化各类型分支 |
| `CachingSecretProvider` | bridge 窗口复用、20s TTL、不同 origin/地址隔离、clearCache、并发只委托一次 |

### 3.2 中间件测试（Fake Provider）

- `requestAccounts`：无回调抛 4001 / 回调拒绝抛 4001 / 回调通过返回过滤后的地址（排除 HD 根）。
- origin 透传：`sendTransaction` / `signMessage` 等断言 SecretProvider 收到正确 origin。
- blank origin 拒绝：`sendTransaction` / `signTransaction` 抛错。
- 链过滤：EVM 只返回当前链、SWTC 只返回 `bip44Code == swtc`。
- 链切换：同链直返、未确认抛 4001、切换后选账户并触发 `onAccountSwitched`。

### 3.3 集成测试（真实 WKWebView）

1. 注入 `ccdao-eip1193-provider-ios.js` + 适配脚本 + `initJs`，加载本地 fixture HTML。
2. 断言 `window.ethereum.request({method:"eth_chainId"})` 本地拦截返回值。
3. `eth_requestAccounts` 走 native（Fake 中间件返回账户），断言 JS 侧 `accountsChanged` / `selectedAddress` 更新。
4. 错误路径：中间件抛 4001，断言 JS Promise reject 且 error.code 正确。
5. `_updateSelectedAddress` / `_updateChainId` 推送后，断言对应事件触发（地址未变不触发）。
6. C-03 回归：断言 `window.ccdao.sendResponse` 不存在。

### 3.4 运行方式（fastlane）

与 vault / webview-bridge 相同，测试统一走 fastlane：

```bash
bundle exec fastlane macos_test     # macOS 单测（无 WebView 用例）
bundle exec fastlane ios_test       # iOS 模拟器：真实 WKWebView 集成测试
```

## 4. 实施清单

- [ ] 在 `Package.swift` 注册 `SwiftDappConnect` target 与 `Resources` 资源
- [ ] 模型：`DAppMethod` / `ChainType` / `WalletAccount` / `DAppConnectError` / RPC payload
- [ ] `WebOrigin` + `isSafeUrl` + 单测
- [ ] Provider 协议与 `CachingSecretProvider`（actor）
- [ ] `EthMiddleware` / `SwtcMiddleware`（`WalletSigning` 协议）
- [ ] `WebAppInterface`（`WKScriptMessageHandlerWithReply` 路由 + origin 校验）
- [ ] `ccdao-eip1193-provider-ios.js`（iOS 传输变体）+ 适配脚本
- [ ] `DAppConnectSdk` 工厂与 JS 生成
- [ ] 单测 / 中间件测试 / 真实 WebView 集成测试
- [ ] 更新仓库 README 与模块 README
