# 03 · 协议与 JS

## 1. 传输

本模块**不新增 JS**：复用 `SwiftWebviewBridge` 内置的 `wallet-bridge.html`（其加载 jcc-wallet-4.0.8 / jingtum-lib / eth-sig-util / ethereumjs-tx-5.4.0），与 Kotlin 的 `androidAssetUrl("wallet-bridge.html")` 一一对应。

调用协议同 SwiftWebviewBridge：

```text
Native ── evaluateJavaScript("PromiseBridge.call(method, params, id)") ──► 隐藏 WebView
JS    ── window.JSBridge.onPromiseResult(id, JSON.stringify({result|error})) ──► Native
```

- 就绪：`wallet-bridge.js` 加载末尾自调 `onBridgeReady()` + native `didFinish` 兜底。
- 默认超时：`timeoutMs = 30_000`，`readyWaitMs = 15_000`（与 Kotlin 一致）。

## 2. wallet-bridge.js 方法协议（Swift 封装对照）

| JS 方法 | 参数 | 返回 | Swift 方法 |
| --- | --- | --- | --- |
| `validateMnemonic` | mnemonic, language | bool | `validateMnemonic` |
| `generateMnemonic` | length, language | `{value, language}` | `generateMnemonic` |
| `deriveChild` | mnemonic, chain, account, change, index, language | `{address, keypair, path}` | `deriveChild` |
| `hdWalletFromMnemonic` | mnemonic, chains[], language | `{mnemonic, address, keypair, accounts[]}` | `hdWalletFromMnemonic` |
| `deriveFromMnemonic` | mnemonic, chain, account, change, index, language | `{address, keypair, mnemonic, path}` | `deriveFromMnemonic` |
| `deriveFromPrivateKey` | privateKey, chain | `{address, keypair, secret}` | `deriveFromPrivateKey` |
| `validatePrivateKey` | privateKey, chain | bool | `validatePrivateKey` |
| `buildSwtcPayment` | address, amount, to, token, memo | string | `buildSwtcPayment` |
| `buildSwtcNftTransfer` | address, to, tokenId, memo | string | `buildSwtcNftTransfer` |
| `signSwtcTransaction` | tx, secret | string(blob) | `signSwtcTransaction` |
| `isValidAddress` | address | bool | `isValidAddress` |
| `signMessage` | address, message, secret | string | `signMessage` |
| `signTransaction` | tx, secret | string(blob) | `signTransaction` |
| `multiSign` | tx, secret | string | `multiSign` |
| `personalSign` | privateKey, data | string | `personalSign` |
| `signTypedData` | privateKey, data, version | string | `signTypedData` |
| `recoverTypedSignature` | data, signature, version | string | `recoverTypedSignature` |
| `recoverPersonalSignature` | data, signature | string | `recoverPersonalSignature` |
| `getEncryptionPublicKey` | privateKey | string | `getEncryptionPublicKey` |
| `decrypt` | privateKey, data | string | `decrypt` |
| `signEthTransaction` | privateKey, tx | string | `signEthTransaction` |
| `buildSwtcCreateOrder` | address, amount, base, counter, sum, type, platform?, issuer? | string | `buildSwtcCreateOrder` |
| `buildSwtcCancelOrder` | address, sequence | string | `buildSwtcCancelOrder` |

## 3. JS 缺口（已补齐）

原缺口 `buildSwtcCreateOrder` / `buildSwtcCancelOrder`（Kotlin `WalletSdk` 暴露但 `wallet-bridge.js` 未实现）——
Kotlin 侧 `webview-bridge` 已补实现（`serializeCreateOrder` / `serializeCancelOrder`，jingtum-lib 导出），
Swift 侧 `Sources/SwiftWebviewBridge/Resources/bridge/wallet-bridge.js` 已同步补齐，与 Kotlin 版本方法集一致
（`diff` 校验仅空行差异）。Swift 侧 `SwiftWallet.buildSwtcCreateOrder` / `buildSwtcCancelOrder` 直接透传。

## 4. 安全注意

- **私钥经 JS 桥**：`personalSign` / `signTypedData` / `decrypt` / `signEthTransaction` 等方法把私钥作为参数注入隐藏 WebView 的 JS 上下文——与 Kotlin 现状一致，但需注意：
  - 隐藏 WebView 只加载本地 bundle 资产（导航策略已白名单限制），不可被远程内容劫持；
  - 桥页面内第三方 min.js 处理私钥，供应链可审计性依赖 `SwiftWebviewBridge` 的资源管理（见仓库 `security-review.md` S3）；
  - 私钥以 `String` 存在，Swift 无法可靠擦除（COW），上层拿到后尽快消费。
- **不要向钱包桥暴露 SwiftVault 主密码**：签名所需密钥由宿主从 `SwiftVault` 解密后传入（与 Kotlin `WalletSdk` 一致），桥本身不参与存储。
