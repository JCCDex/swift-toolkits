# 安全审查与优化清单

> 生成于 2026-08-18，覆盖 commit `2b7477a`。示例（Demo）相关项已排除。
> 图例：🔴 高风险 / 🟠 中风险 / 🟡 低风险加固 / ⚙️ 优化

## 已修复（2026-08 会话）

| 项 | 内容 |
| --- | --- |
| H1 | DAppConnect 消息来源伪造：仅接受主 frame，origin 按 `frameInfo.securityOrigin` 实时推导（不再信任宿主全局状态） |
| M1 | 响应伪造：`_ccdaoSettle` token 鉴权 + `Object.defineProperty` 冻结；`WKScriptMessageHandlerWithReply` 方案经实测不可行（reply 在 xctest 进程不送达），详见 `03-protocol-and-js.md` |
| M2 | 状态伪造：provider 状态收进 IIFE 闭包，`_ccdaoNative` token 鉴权 + 冻结 |
| CI | `docs:` / `demo:` 开头的提交跳过测试 |

---

## 🔴 高风险（建议优先处理）

### H2. 签名/交易无用户确认钩子（静默签名风险）

- **位置**：`EthMiddleware.swift:71-101`（personalSign/signTypedData/getEncryptionPublicKey/decrypt）、`WebAppInterface.swift:431-452`（didIssueCredential/ipfsPersonalSign）
- **问题**：所有签名方法直接 `secretProvider.getPrivateKeyForAddress(...)` 取私钥即签，SDK 内没有「展示消息/交易内容给用户确认」的回调。若宿主 SecretProvider 只做密码/生物识别解锁，恶意 DApp 可盲签 personal_sign（经典钓鱼）或 typed data 中的 permit/approve（**直接清空资产**）。
- **建议**：仿照 `RequestAccountsCallback`（M-06）新增 `SigningApprovalCallback`，`personalSign / signTypedData / signTransaction / sendTransaction / decrypt / didIssueCredential` 执行前强制调用。

### H3. `eth_sendTransaction` 签名即广播 + gas 静默回落

- **位置**：`EthMiddleware.swift:185-191, 157-165`
- **问题**：`sendTransaction = sign + broadcastTransaction` 一步完成，无交易详情确认环节（依赖 H2 的钩子）；`estimateGas` 失败**静默回落 0x5208（21000 gas）**——合约调用会 out-of-gas 烧掉用户 gas。
- **建议**：broadcast 前必须有确认；estimateGas 失败应返回 `DAppConnectError.transaction` 而非默认值。

---

## 🟠 中风险

### M3. 任意地址查询 NFT/账户名 → 隐私泄露

- **位置**：`WebAppInterface.swift:223-236, 412-415`
- **问题**：`eth_requestNfts` / `swtc_requestNfts` / `did_requestAccountName` 接受 DApp 传入的**任意 address**，可枚举他人 NFT 持仓与账户名。
- **建议**：校验 address ∈ 该 origin 已授权账户列表。

### M4. `swtc_requestAccounts` 静默强制切链

- **位置**：`WebAppInterface.swift:259-269`
- **问题**：DApp 调用时直接 `setCurrentChain(.swtc)` 无用户确认，还会污染 eth 中间件的全局 `currentChain` 状态。
- **建议**：走 `chainProvider.requestChainSwitch`（带确认）。

### M5. WebviewBridge 导航策略放行任意 `file://` URL

- **位置**：`WebviewBridgeClient.swift:328-343`
- **问题**：`decidePolicyFor` 对所有 file URL 放行，应限制在 bridge 目录前缀；顺带 `destroy()` 里 `loadBlank()`（about:blank）会被该策略 cancel，属行为 bug。
- **建议**：白名单限定 `resolveBridgeURL().deletingLastPathComponent()`。

### M6. 错误信息向不可信 DApp 泄露内部细节

- **位置**：`WebAppInterface.swift:551-556`
- **问题**：`failure()` 直接回传 `error.localizedDescription`（keychain 错误、内部路径等）。
- **建议**：对 DApp 只回通用 message（`DAppConnectError` 已含 code），详情仅记原生日志。

### M1/M2 方案的残余风险

- `responseToken` **静态、无轮换**：整个 webview 会话不变。若宿主日志/崩溃上报泄露了注入 JS 或 token 值，可一直复用。
- `_ccdaoSettle` 仍是全局（虽已冻结）：SPA 重载后若入口被页面冲掉，native `deliver` 静默失败 → DApp 等 60s 超时（健壮性而非安全）。
- **建议**：token 在 `lock()`/切后台时轮换（需重新注入 provider）；`deliver` 前检测入口存在性。

---

## 🟡 低风险 / 加固

### SwiftVault

| # | 位置 | 问题与建议 |
|---|---|---|
| V2 | `ProtobufVaultStoreDriver.swift:85` | `vault.pb` 无文件保护：iOS 加 `.completeFileProtection`，macOS 加 0600；`clearAllData` 先覆写旧文件再写空快照（防取证残留） |
| V3 | `VaultRepository.swift:37-39,322` | `lock()`/`changePassword` 只置 nil **未 wipe 会话密钥**；`Wipe.swift` 内部从未使用。建议置 nil 前清零，文档注明 COW 局限 |
| V4 | `VaultRepository.swift:46-48` | `initializePassword` 默认固定 64MiB，`Argon2ParamChooser` 未接入默认路径；建议按设备自适应 |
| V5 | `VaultRepository.swift:393-404` | 已解锁时 `ensureUnlocked` 仍重跑 Argon2 验证密码（性能开销） |
| V6 | proto `private_key_vault.proto:30` | `PasswordEntry.proof_iv` 字段 Swift 端未使用（Kotlin 残留） |
| V7 | `TinkVaultCipher.swift:72` | keychain 写入未显式指定 accessibility，建议 `ThisDeviceOnly` |
| V8 | `VaultRepository.swift:113-125` | `importPrivateKey` 不校验 address 与私钥是否匹配 |

### SwiftWebviewBridge

| # | 位置 | 问题与建议 |
|---|---|---|
| W1 | `BridgeMessageHandler.swift:15-18` | 消息 handler 不检查 `frameInfo.isMainFrame`（同 H1 模式；本地 bundle 风险低，防御纵深建议加） |
| W2 | `WebviewBridgeClient.swift:112` | `PromiseBridge.call` 返回 Promise，`evaluateJavaScript` 无法序列化；建议脚本 `;null` 结尾避免未定义行为 |
| W3 | `ContinuationBox.swift:6-18` | `@unchecked Sendable` 的 `continuation` 在 onCancel 与主线程间并发读写，理论双 resume 数据竞争；建议锁保护 |
| W4 | `BridgeScripts.swift:26-44` | console 转发（`allowsConsoleForwarding`）会把页面日志打进系统 NSLog，可能含敏感数据 |

### SwiftDappConnect

| # | 位置 | 问题与建议 |
|---|---|---|
| D1 | `CachingSecretProvider.swift` | 私钥以不可擦除的 `String` 缓存 5–20s；`clearCache` 依赖宿主在断开/切后台调用；origin↔address 授权完全依赖 delegate 实现 |
| D2 | `WebOrigin.swift:9-23` | 不处理尾部点（`example.com.`）与 IDN punycode |
| D3 | `DAppConnectSdk.swift` jsQuote | 手工转义不完整（未处理 `\u2028/29`、NUL）；建议改用 JSONSerialization 生成字面量 |
| D4 | `ccdao-eip1193-provider-ios.js:136` | `isMetaMask: true` 伪装 MetaMask（兼容性取舍，需知悉）；`request()` 未校验 `args` 类型（undefined method 会抛错后 60s 超时） |
| D5 | `did-bridge.js:75-77` | **硬编码生产 IPFS 网关** `https://wodecards.wh.jccdex.cn:8550`（单点故障 + 供应链），建议配置注入 |
| D6 | `SwtcMiddleware.swift:87-89` | `sendTransactionWithPassword(password:)` 的 password 参数被忽略（若宿主期望密码即确认，此路径绕过） |

### 供应链 / 工程

| # | 位置 | 问题与建议 |
|---|---|---|
| S1 | `Package.swift:98` | **`Argon2Swift` 依赖 `branch: "main"`、`phc-winner-argon2` 依赖 `branch: "master"`**（可变分支，上游可静默改动）；建议固定 commit/tag |
| S2 | `Package.swift:99` | `SwiftFormat`（纯开发工具）作为运行时依赖打进每个消费者 |
| S3 | 5 个 `*.min.js`（处理私钥的 ethereumjs-tx / eth-sig-util / jcc-wallet 等） | 无上游 commit/SRI/来源文档，供应链可审计性差；建议记录精确版本 + sha256 |
| S4 | `Vendor/Tink/Tink.xcframework` | 二进制直接提交 git，无校验和 |
| S5 | `.github/workflows/ci.yml` | 无 SAST/依赖漏洞扫描；建议加 Semgrep（手工 JS 拼接、isMainFrame 缺失等模式）+ 依赖审计 |

---

## 优化点（非安全）

1. **性能**：V5（已解锁时跳过重复 Argon2）；`CachingSecretProvider` 缓存窗口按场景调优。
2. **一致性**：`WebOrigin.normalize` 与 `DAppConnectSdk.isSafeUrl` 两套 URL 校验并存，建议合并为单一实现。
3. **健壮性**：`handleEthRequestNfts` 的 chainId 解析对十进制字符串会解析错（`WebAppInterface.swift:500-501`）；provider JS `request()` 对 `args` undefined 未防御。
4. **测试**：补充 protobuf 畸形输入 fuzz、GCM 密文篡改/换位测试、iframe 消息注入回归（H1 修复后）；WithReply 方案若未来采用，需独立 xctest 进程 + 单 webview + 挂窗口的冒烟设计（实测结论见 `03-protocol-and-js.md`）。
5. **文档**：`03-protocol-and-js.md` 可补一句「WithReply 下 M1 免疫、仅 M2 需 token」，方便日后切换方案对照。

---

## 建议处理顺序

**H2**（签名确认钩子）→ **H3**（交易确认 + gas 处理）→ **M3/M4**（隐私与切链确认）→ **M5/M6** → **Vault 加固**（V2/V3 优先）→ **供应链**（S1 最紧急）→ 其余加固项。
