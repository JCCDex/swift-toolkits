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

## 3. 硬编码 IPFS 网关（迁移必修项）

`did-bridge.js` 当前硬编码：

```js
const client = new IpfsClient({ baseURL: "https://wodecards.wh.jccdex.cn:8550" });
```

问题（`security-review.md` D5）：生产网关写死在库资产里，单点故障 + 换环境不可配。

**方案**：把 `did-bridge.js` 中的 baseURL 改为占位符，由 Swift 侧注入：

```js
const client = new IpfsClient({ baseURL: /*__CCDAO_DID_IPFS_BASE_URL__*/ null });
```

**注入机制（可落地，二选一）**：

- **方案 A（推荐）**：`did-bridge.html` 用 `<script src>` 引用 bundle 内 `did-bridge.js`，bundle 只读、不能原地改文件。SwiftDid 把**修改后的 `did-bridge.js` + `did-bridge.html` + `did-0.3.2.min.js` + `jcc-wallet-4.0.8.min.js`** 整套复制到持久缓存目录（`Application Support/Did/bridge-<hash>/`，按整个资产集内容 hash 缓存，见 04 坑 #22；勿用 `temporaryDirectory`，会被系统清理、缓存失效），用 `Bundle(path:)` 包一层，再以 `WebviewBridgeConfig(bridgeFileName: "did-bridge.html", resourceBundle: tempBundle)` 交给自持的 `WebviewBridgeClient`。WKWebView 的 read-access 只指向该缓存目录，同目录资产可相对引用，Swift 侧无需改 `WebviewBridgeClient`。
- **方案 B（对齐 DappConnect 注入 provider 的成熟模式）**：`did-bridge.js` 改为从全局读网关（`const client = new IpfsClient({ baseURL: window.__CCDAO_DID_IPFS_BASE_URL__ });`），SwiftDid 通过 `WKUserScript(.atDocumentStart)` 预置该全局；未预置时 JS 侧 fail-closed。

**校验与 fail-closed**：`ipfsBaseURL` 只接受 http/https 且 host 合法（复用 `DAppConnectSdk.isSafeUrl` 的校验思路，拒绝 `javascript:`/`file:`）；native 在 `start()` 检测占位符残留/未配置即抛 `SwiftDidError.ipfsBaseURLNotConfigured`；JS 侧保留 `baseURL: null` 的构造失败兜底。默认值不放代码里，由宿主从远端配置/环境注入。

**资产同步**：占位化会令 Swift 与 Kotlin 的 `did-bridge.js` 产生永久差异，与 04 章「diff 对齐」冲突。建议 Kotlin 侧同步占位化（`baseURL` 也改为注入），或至少在文档/CI 中记录这处**唯一允许的差异**，diff 校验时白名单放行。

## 4. 密钥经桥安全

- `signCredential` / `generateVC` / `ipfsPersonalSign` / `generatePublicKeyBase58` 等把私钥传入隐藏 WebView JS 上下文——与 Kotlin 现状一致。隐藏 WebView 只加载本地 bundle 资产（导航白名单），不可被远程内容劫持。
- `signCredentialForDApp` 只做结构校验（M-15），**用户确认必须由宿主 UI 完成**——恶意 DApp 可构造任意 VC 内容要求签名，钱包须展示待签内容。
- `signCredential` 还强依赖 `keyDoc.did`/`keyDoc.id`（`did-bridge.js` 内显式校验），`signCredentialForDApp` 的结构校验须把 keyDoc 一并纳入（M-15 三条 + keyDoc 两条），先于桥报错并返回 `SwiftDidError.invalidCredential`，避免把桥内字符串错误透传给 DApp。
- 私钥以 `String` 存在，Swift 无法可靠擦除（COW），上层调用后尽快丢弃引用（同 `SwiftWallet`）。
