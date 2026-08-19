# 03 · 协议与 JS

## 1. 传输

复用 `SwiftWebviewBridge` 内置的 `did-bridge.html`（加载 `jcc-wallet-4.0.8.min.js` + `did-0.3.2.min.js`），与 Kotlin `androidAssetUrl("did-bridge.html")` 对应。调用协议同 SwiftWebviewBridge（`PromiseBridge.call(method, params, id)` → `onPromiseResult(id, {result|error})`）。

> 注意：SwiftWebviewBridge 的 `did-bridge.html` / `did-bridge.js` 与 Kotlin `:webview-bridge` 资产应保持同步（同 `wallet-bridge` 的做法，迁移时先 `diff` 对齐）。

## 2. did-bridge.js 方法协议（Swift 封装对照）

| JS 方法 | 参数 | 返回 | Swift 方法 |
| --- | --- | --- | --- |
| `didResolve` | did | doc JSON 字符串（缺失返回 null） | `resolveDid` |
| `didStat` | did | `{cid}` | `didStat`（写操作填 previousCid） |
| `publishDid` | did, privateKey, didDocument | `{code, message}` | `publishDid` |
| `generatePublicKeyBase58` | privateKey | `{publicKeyBase58, type}` | `didGenerateBase58PublicKey` |
| `signCredential` | credential/keyDoc/privateKey/… | 签名后 VC（JSON 字符串） | `signCredentialForDApp`（**JS 强依赖 `keyDoc.did`/`keyDoc.id`**，native 结构校验须先于桥报错，见 §4） |
| `ipfsGetPublicKey` | privateKey | 压缩公钥 hex | `ipfsGetPublicKey` |
| `ipfsPersonalSign` | privateKey, data(int[]) | DER(hex) 签名 | `ipfsPersonalSign` |
| `generateVC` | id/types/subject/privateKey/address/did/expirationDate/contextType | VC JSON | `addCredentialToDid`/`updateDidAvatar` 内部 |
| `verifyCredential` | credential | `{verified, errorKind, error, results}` | `verifyCredential`（Swift 模型保留 `errorKind`/`error`，Kotlin 丢弃了这两个字段） |
| `generateDidDoc` | version/authentications/… | DID 文档 JSON | 初始文档生成 |

> **缺失文档哨兵**：`didResolve` 对未解析到的 DID 返回 JS `null`，经 WebView 序列化为字符串 `"null"`；
> 旧 IPFS tombstone 为 `"{}"`。Swift `resolveDid` 返回 `DidResolveOutcome` 三态（`missing/error/document`，见 04 坑 #15），
> 须同时把 `"{}"`、`"null"` 与**空串（trimmed 后）**都判定为 `missing`（对齐 Kotlin `DidResolveUtils.isMissingDidDocument`，并补空串防御），
> 否则 `resolveOwnerDidDocument` / `resolveBaseDoc` 会把缺失文档当成有效文档处理。

## 3. IPFS 网关（保持硬编码，不注入）

`did-bridge.js` 当前硬编码：

```js
const client = new IpfsClient({ baseURL: "https://wodecards.wh.jccdex.cn:8550" });
```

**决策（2026-08 实现）**：网关**保持硬编码、不做注入**——`EngineDidBridge.start()` 直接用 SwiftWebviewBridge 默认 bundle 加载 `did-bridge.html`（`resolveBridgeURL` 自动落到 `bridge/` 子目录），**无临时 bundle、无占位符替换、无 `ipfsBaseURL` 配置面**（`SwiftDid` init / `SwiftDidError` 均不含网关相关项）。

> ⚠️ 已知接受项：`security-review.md` D5（生产网关写死在库资产里，单点故障 + 换环境不可配）**未修复**，与 Kotlin `:did` 现状一致（Kotlin 的 `:nft` 同样硬编码 `DEFAULT_IPFS_GATEWAY_BASE_URL`）。若日后需要可配置网关，再回到注入方案（占位符替换 + 临时 bundle / `WKUserScript` 预置全局），届时注意：占位化会令 Swift 与 Kotlin 的 `did-bridge.js` 产生永久差异，diff 对齐时需白名单放行这处唯一允许的差异。

## 4. 密钥经桥安全

- `signCredential` / `generateVC` / `ipfsPersonalSign` / `generatePublicKeyBase58` 等把私钥传入隐藏 WebView JS 上下文——与 Kotlin 现状一致。隐藏 WebView 只加载本地 bundle 资产（导航白名单），不可被远程内容劫持。
- `signCredentialForDApp` 只做结构校验（M-15），**用户确认必须由宿主 UI 完成**——恶意 DApp 可构造任意 VC 内容要求签名，钱包须展示待签内容。
- `signCredential` 还强依赖 `keyDoc.did`/`keyDoc.id`（`did-bridge.js` 内显式校验），`signCredentialForDApp` 的结构校验须把 keyDoc 一并纳入（M-15 三条 + keyDoc 两条），先于桥报错并返回 `SwiftDidError.invalidCredential`，避免把桥内字符串错误透传给 DApp。
- 私钥以 `String` 存在，Swift 无法可靠擦除（COW），上层调用后尽快丢弃引用（同 `SwiftWallet`）。
