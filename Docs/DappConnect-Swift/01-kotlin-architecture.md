# 01 · Kotlin 版架构

## 1. 模块文件清单

```text
dapp-connect/src/main/
├── assets/ccdao-eip1193-provider.js   // EIP-1193 provider（window.ethereum / window.ccdao）
└── java/com/jccdex/toolkits/dappconnect/
    ├── DAppConnectSdk.kt              // 唯一入口：中间件工厂 / JS 加载 / URL 安全 / EIP-6963
    ├── WebAppInterface.kt             // _tw_ 接收端：消息路由到中间件（@JavascriptInterface）
    ├── WebAppInterfaceWithWebView.kt  // 带响应通道的实现（NativeResponseChannel 接线）
    ├── NativeResponseChannel.kt       // WebMessagePort 原生→JS 响应通道（C-03）
    ├── WebOrigin.kt                   // origin 归一化 + WALLET_INTERNAL 哨兵（M-18）
    ├── DidDocumentMutationListener.kt // DID 文档变更通知
    ├── middleware/
    │   ├── MiddlewareInterfaces.kt    // IEthMiddleware / ISwtcMiddleware / RequestAccountsCallback
    │   ├── EthMiddleware.kt           // EVM 方法实现
    │   └── SwtcMiddleware.kt          // SWTC 方法实现
    ├── model/
    │   ├── DAppMethod.kt              // 方法名枚举（含 UNKNOWN）
    │   └── Models.kt                  // JsonRpcResponse / JsonRpcError / 异常（错误码）
    └── provider/
        ├── Interfaces.kt              // Account/Secret/Node/Chain/Nft Provider
        └── CachingSecretProvider.kt   // 批次密码缓存包装器
```

## 2. 请求流

```text
DApp JS ── window._tw_.postMessage(json) ──► WebAppInterface.postMessage
    │
    ├─ 校验：origin 非空（M-05）且 isSafeUrl 通过
    ├─ 解析 {name, network, id, nonce, params}
    ├─ DAppMethod.fromValue(name) 路由
    │     └─ 每个 handler 在 CoroutineScope(IO) 里调中间件 async 方法
    ├─ 成功 ──► sendSuccessResponse(network, nonce, result)
    └─ 异常 ──► sendErrorResponseWithCode / sendErrorResponse
                          │
                          ▼
              NativeResponseChannel（WebMessagePort）──► JS requestQueue[nonce] settle
```

- 响应带 `nonce`，JS 侧 `requestQueue` 以 nonce 匹配回调，先到先删；非法的 `window.ccdao.sendResponse` 不再暴露（C-03）。
- 日志只打 method/network，**不打 payload**（可能含交易、消息、密文）。

## 3. 关键流程

### 3.1 requestAccounts（EVM / SWTC）

1. 强制要求 `setRequestAccountsCallback`（M-06，破坏性）；未设置直接抛 `UserRejectedException(4001)`。
2. 回调返回是否授权；拒绝同样抛 `UserRejectedException`。
3. 取 `accountProvider.accounts` 首值，按当前链过滤，**排除 HD 根账户**（`isHD && parentId == null`）。
4. 返回地址数组。

### 3.2 eth_signTransaction / eth_sendTransaction

- origin 必须非空；校验 `from` 账户存在且属于 EVM 链。
- chainId 优先级：tx 参数 > 当前链状态 > 账户链；未知 chainId 回落当前链。
- 自动补全：nonce（`getTransactionCount`）、EIP-1559（maxFee/maxPriorityFee，缺失时取网络值或回退 `0x1`）或 legacy gasPrice、gas（估算失败回退 `0x5208`）。
- 用 `WalletSdk.signEthTransaction` 签名；send 再经 `broadcastTransaction` 上链。

### 3.3 wallet_switchEthereumChain

- 解析 chainId（hex/十进制）→ 查 `ChainType`；不支持抛 `ChainNotSupportedException(4902)`。
- 目标链 == 当前链直接成功；否则 `ChainProvider.requestChainSwitch` 用户确认，拒绝抛 4001。
- 切换后自动选账户：优先同地址账户，否则目标链第一个账户；`setCurrentAccount` + 通知 `onAccountSwitched`。

### 3.4 SWTC 方法

- `swtc_requestAccounts`：按 `bip44Code == SWTC` 过滤并排除 HD 根账户。
- `swtc_sendTransaction` / `multiSign` / `signMessage`：校验账户与链，`Sequence` 缺失时 `fetchSequence`，经 `WalletSdk` 签名后 `sendRawTransaction`。
- 原生 UI 路径：`sendNftTransactionWithPassword` 用 `WebOrigin.WALLET_INTERNAL` 作为 origin（M-18），避免空白 origin。

### 3.5 DID / IPFS / NFT

- DID 方法经注入的 `DidSdk`：`didGenerateBase58PublicKey` / `signCredentialForDApp` / `ipfsPersonalSign` / `ipfsGetPublicKey`；取私钥统一走 `getPrivateKeyOrFail`（SecretProvider + 当前 origin）。
- `ipfs_personalSign` 成功后通知 `DidDocumentMutationListener`。
- NFT：`nftProvider` 未配置时返回空结构（`{address, total:0, nfts:[]}`）；ETH NFT 白名单、分组与 ERC721 元数据按 Kotlin 序列化规则对齐。

## 4. 安全规则（M-xx 契约）

| 规则 | 内容 |
| --- | --- |
| M-05 | postMessage 拒绝空白或非安全 origin；宿主必须在导航时 `setOrigin` |
| M-06 | requestAccounts 必须设置回调，未设置视为用户拒绝（4001） |
| M-15 | `signCredentialForDApp` 只校验 VC 结构，用户确认由宿主 UI 完成 |
| M-18 | 原生 NFT 等内部取密钥用 `WebOrigin.WALLET_INTERNAL` 哨兵，不可作为可授权 web origin |
| M-R4 / H-R2 | origin 归一化为 `scheme://host[:port]`（去默认端口） |
| C-03 | 响应经 `WebMessagePort` 通道回传，不再依赖 `window.ccdao.sendResponse` |

## 5. Provider 与缓存

`AccountProvider`（账户列表/当前账户/按地址查找/设置当前账户/账户名）、`SecretProvider`（按 origin 取私钥/秘钥）、`NodeProvider`（RPC URL/blockNumber/nonce/gas/估算/广播）、`ChainProvider`（链切换确认 + 支持链）、`NftProvider`。

`CachingSecretProvider` 缓存规则：

- 批次内复用：同一 `origin|address` 首次取钥后，5 秒内不再委托（不重复弹密码）。
- 绝对上限 20 秒：超过强制重新认证。
- `clearCache()`：切后台 / 锁屏 / 切换账户时调用。
- 私钥与秘钥分别加互斥锁，避免同地址并发重复弹窗。

## 6. 测试基线（移植验收对照）

| 测试文件 | 覆盖点 |
| --- | --- |
| `DAppConnectSdkTest` | isSafeUrl（https/http/端口/路径/query/域名）；loadAddressJs 的 EVM/SWTC 分支 |
| `WebOriginTest` | normalize：默认端口省略、非法 scheme/host 返回 null |
| `NativeResponseChannelTest` | 响应 payload 序列化（result 类型分支） |
| `WebAppInterfaceJsCallbackTest` | 非端口通道的 JS 回调转义（保留给单测） |
| `ProviderJsC03RegressionTest` | provider JS 不再暴露 sendResponse 的回归检查 |
| `EthMiddlewareTest` / `SwtcMiddlewareTest` | requestAccounts 回调三态、HD 根过滤、origin 传递、blank origin 拒绝 |
| `CachingSecretProviderTest` | 缓存窗口、不同 origin/地址隔离、clearCache、并发只委托一次 |

Swift 移植的测试策略见 [04-migration-and-testing.md](04-migration-and-testing.md)。
