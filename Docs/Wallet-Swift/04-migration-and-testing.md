# 04 · 迁移与测试

## 1. Kotlin → Swift 逐项对照

| Kotlin | Swift | 说明 |
| --- | --- | --- |
| `object WalletSdk` | `final class SwiftWallet` + `.shared` | @MainActor 单例 |
| `initialize(context)` | `start()` | 无需 Context；幂等 |
| `destroy()` | `destroy()` | 同语义，可重建 |
| `callJsMethod` / `callJsMethodAs` | `engine.callJsMethod` / `callJsMethodAs` | 复用 SwiftWebviewBridge |
| `JSONObject` | `[String: Any]` / `Encodable` | 字典参数 |
| Gson `parse` | `JSONDecoder` | `callJsMethodAs` 内置 |
| `Keypair/Path/Mnemonic/SubWallet/GenerateHDWalletResult/TraditionalDeriveResult` | 同名 `struct` | 字段一一对应 |
| `chain: Long` | `chain: Int64` | 与 `ChainType.bip44Code` 数值一致 |
| `AndroidWalletWebRuntime` / `IWalletBridge` | 不需要（SwiftWebviewBridge 已封装运行时） | 平台差异 |
| 签名供 DApp 层调用 | 实现 `WalletSigning` 注入中间件 | SwiftDappConnect 对接 |

## 2. 实现注意点 / 坑

1. **就绪语义**：`WebviewBridgeEngine.start()` 后首次 `callJsMethod` 会等 `onBridgeReady`（默认 15s 兜底）；`SwiftWallet.start()` 内先 `start()` 再置 `started = true`，避免竞态。
2. **`signTransaction` 返回 blob**：JS 返回 `signedTx.blob`（SWTC）；`signEthTransaction` 返回十六进制序列化交易——两者都是 `String`，Swift 不做二次解析，直接透传。
3. **`decrypt` 的 data 预处理**：wallet-bridge.js 对 `0x` 前缀的 data 先 hex 解码再 `JSON.parse`；Swift 层原样透传即可，不要预先解码。
4. **`chains` 数组参数**：`hdWalletFromMnemonic(chains: [Int64])` 经 JSON 序列化为数组，JS 端 `chains.map(...)` 遍历；空数组 = 只返回根账户。
5. **JS 缺口（已补齐）**：`buildSwtcCreateOrder` / `buildSwtcCancelOrder` 已按 Kotlin `webview-bridge` 同步到 Swift `wallet-bridge.js`（jingtum-lib 已含 `serializeCreateOrder`/`serializeCancelOrder`），Swift 直接透传（见 03 章）。
6. **私钥/助记词 String 生命周期**：桥返回的 `String` 不可擦除；上层（SecretProvider）从 `SwiftVault` 取密后调用完即刻丢弃引用。

## 3. 测试策略

| 层级 | 方式 | 覆盖 |
| --- | --- | --- |
| 单测（Fake 桥） | 仿 Kotlin `installBridgeForTest`：SwiftWebviewBridge 的 `WebviewBridgeClient(gateway:runtimeFactory:)` 注入 `FakeRuntime` | 参数构造、返回解析（`SubWallet` 等模型）、`notInitialized` 抛错、超时参数透传 |
| 行为契约 | 对齐 Kotlin `WalletSdkTest` 用例 | validateMnemonic 布尔解析、deriveChild 参数、sign 方法透传 |
| 真实 WebView 冒烟（iOS） | 复用 SwiftWebviewBridge 集成测试基建，加载 `wallet-bridge.html` 后调 `generateMnemonic` / `deriveChild`（chain=ETH） | 端到端 JS 执行（与 WalletDemo 相同的桥链路） |
| WalletSigning 对接 | 中间件测试注入 `SwiftWallet`（Fake 桥） | personalSign/signTypedData/signEthTransaction 转发 |

> 单测全部走 FakeRuntime，**不依赖真实 WebKit**（macOS `swift test` 可跑）；真实 WebView 用例放 iOS 模拟器（fastlane `ios_test`），与 SwiftWebviewBridge 同策略。

## 4. 实施清单

- [x] `Package.swift` 注册 `SwiftWallet` target（依赖 `SwiftWebviewBridge` + `SwiftDappConnect`）
- [x] `WalletModels.swift`：6 个 `Codable` 模型 + 单测
- [x] `SwiftWallet.swift`：生命周期 + 23 个类型化方法（含补齐的 create/cancel order）
- [x] `WalletSigning` conformance + 对接单测
- [x] 单测（FakeWalletBridge，对应 Kotlin `installBridgeForTest`）
- [x] 更新仓库 README 与模块 README
- [x] 接入 `Examples/WalletDemo`：用 `SwiftWallet` 替换 `DemoWalletSigning` 桩
