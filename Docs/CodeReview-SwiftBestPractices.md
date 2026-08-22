# swift-toolkits 代码评审报告（Swift 最佳实践 / 命名 / 性能）

> 评审范围：`Sources/` 全部 8 个模块（SwiftCore / SwiftVault / SwiftWebviewBridge / SwiftDappConnect / SwiftWallet / SwiftNft / SwiftDid / SwiftAccount），74 个源文件，约 9,300 行。
> 评审方式：逐文件静态审查（子代理并行 × 7 模块）+ 主代理亲自通读核心文件交叉验证 + `swift build` 增量构建验证。
> 结论：**无强制解包 / 无 `try!` / 无 `fatalError`**（全库 grep 验证）；Swift 6 并发纪律总体优秀。主要问题集中在：访问控制过宽、错误被静默吞掉、主线程阻塞 I/O/JSON、KDF 与存储 IO 重复执行、命名一致性。

## P0 — 必须修复（6 项）

### P0-1 SwiftVault：`getPrivateKeyInternal` 等三个方法为 `public`，绕过密码校验

`Sources/SwiftVault/repository/VaultRepository.swift:333 / 341 / 349`

`getPrivateKeyInternal` / `getMnemonicInternal` / `getSecretInternal` 直接解出明文私钥/助记词，**不经过 `ensureUnlocked` 的密码复核**。任何持有 `VaultRepository` 引用的代码（解锁后）都能在无密码的情况下取走私钥——三个安全包装方法（`:230-243`）形同虚设。

```swift
// 修复：改 private（测试如需访问，用公开的 getPrivateKey(address:password:)）
private func getPrivateKeyInternal(address: String) throws -> Data
```

### P0-2 SwiftWebviewBridge：`ContinuationBox` / `ReadyWaitBox` 跨线程 double-resume 竞态 → 崩溃

> ✅ **已修复（2025-08-22）**：两处 `onCancel` 统一跳回主线程（`WebviewBridgeClient.callJsMethod`
> 的 resume + `PromiseGateway.waitForReady` 的 `box.cancel()`），消除取消线程对 box /
> `gateway.readyListeners` 的并发访问；`ContinuationBox` 另加 `NSLock`（`install` / `take` 原子化，
> 先到先赢）作纵深防御，`ReadyWaitBox` 保持 @MainActor-only 并更新注释。
> 新增 3 个回归测试：`test_continuationBox_concurrentResume_resumesExactlyOnce`（确定性并发双路
> resume，修复前 double-resume 崩溃）、`test_callJsMethod_cancelledFromBackgroundThread_resumesExactlyOnce`
> （FakeRuntime 注入）、`test_waitForReady_cancelledFromBackgroundThread_resumesExactlyOnce`；
> 快速套件 28/28 通过。

`Sources/SwiftWebviewBridge/ContinuationBox.swift:6-44`、`WebviewBridgeClient.swift:125-132`

两个 box 以「字段只在 @MainActor 读写」为由标注 `@unchecked Sendable`，但 `withTaskCancellationHandler` 的 `onCancel` 闭包**在取消线程同步执行，不在主线程**。`WebviewBridgeClient.callJsMethod` 的 `onCancel`（`:131`）直接调用 `box.resume(throwing:)`，与主线程上 JS 结果路径的 `box.resume(with:)`（经 `PromiseGateway.finish` → `onResult`）并发读写 `continuation`——两个线程都读到非 nil 并各自 resume → `CheckedContinuation` **double-resume 崩溃**（release 下也是硬崩溃）。`ReadyWaitBox.cancel()` 里的 `remover?()` 同样会从取消线程改写 `gateway.readyListeners` 字典（数据竞争）。

```swift
// 修复（二选一）：
// A. 给 box 加锁，取走续体再 resume：
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    func resume(with result: Result<T, Error>) { take()?.resume(with: result) }
    func resume(throwing error: Error)      { take()?.resume(throwing: error) }
    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil; return c
    }
}
// B. onCancel 内全部跳主线程：Task { @MainActor in ... }
```

### P0-3 SwiftWebviewBridge：`clearAll()` / `destroy()` 让 in-flight 续体永久悬挂

> ✅ **已修复（2025-08-22）**：`clearAll()` 现在先取走全部 pending 调用、清空表，再逐个
> `timeoutTask.cancel()` + `onResult(.failure(.webViewUnavailable))`——destroy 中途的调用者
> 以 `webViewUnavailable` 恢复，不再永久悬挂。新增 2 个回归测试
> （`test_clearAll_resumesPendingCallbacksWithError` 网关层、`test_callJsMethod_destroyWhileInFlight_resumesWithError`
> 客户端层，FakeRuntime 注入），快速套件 30/30、完整 `SwiftWebviewBridgeTests` 通过。

`Sources/SwiftWebviewBridge/PromiseGateway.swift:107-114`、`WebviewBridgeClient.swift:56-71`

`clearAll()` 只取消超时任务并清空 `pending`，**从不 resume 已注册的 onResult**。`destroy()` 中途调用时：超时任务被取消（超时路径失效）、pending 被清（JS 迟到回调变 no-op）→ 调用方的 `withCheckedThrowingContinuation` 永远不会被恢复 → `callJsMethod` 永久挂起，并强持有 client/box/闭包。现有测试只断言 `isReady`/`pendingCount`，未覆盖此路径。

```swift
func clearAll() {
    let calls = Array(self.pending.values)
    self.pending.removeAll()
    for call in calls {
        call.timeoutTask.cancel()
        call.onResult(.failure(WebviewBridgeError.webViewUnavailable)) // 补上
    }
    self.readyListeners.removeAll()
    self.isReady = false
}
```

### P0-4 SwiftNft：`decodeAbiString` 整数溢出 → 恶意合约可触发运行时崩溃

> ✅ **已修复（2025-08-21）**：`length` 解析后在乘法前先按剩余数据量界住
> （`length <= (normalized.count - 128) / 2`），`length * 2` 不再可能溢出；同时移除被
> 该界长隐含的冗余尾部 guard。新增 2 个回归测试
> （`testDecodeAbiStringRejectsOverflowLength` 覆盖 2^62 / 2^63-1 两个溢出临界值、
> `testDecodeAbiStringLengthExactlyFitsData` 覆盖 length=可用数据长度的边界防过度拦截），
> `EthTokenUriResolverTests` 18/18、完整 `SwiftNftTests` 129/129 通过。

`Sources/SwiftNft/Net/EthTokenUriResolver.swift:78-81`

```swift
guard let length = Int(normalized[64 ..< 128], radix: 16), length >= 0 else { return nil }
let dataStart = 128
let dataEnd = dataStart + length * 2        // ← length 可达 2^63-1，×2 溢出 Int64 → 运行时 trap
guard normalized.count >= dataEnd else { return nil }  // 溢出发生在该 guard 之前
```

ABI 长度字是 64 hex 位（最大 2^64-1），`length` 可解析到 [2^62, 2^63) 区间，`length * 2` 直接溢出崩溃。**入参来自链上不可信数据**（NFT 合约 `tokenURI` 返回值），属远程可触发崩溃。

```swift
// 修复：先按剩余长度界住，再做乘法
guard normalized.count >= 128 else { return nil }
guard let length = Int(normalized[64 ..< 128], radix: 16), length >= 0, length <= (normalized.count - 128) / 2 else { return nil }
let dataEnd = 128 + length * 2   // 此时 length*2 不会溢出
```

### P0-5 SwiftAccount：`persistVault` 用 `try?` 吞掉全部 vault 错误 → 账户「成功」但私钥未入库

> ✅ **已修复（2025-08-21）**：`persistVault` 改为 `async throws`，三个分支 `try? await` → `try await`，
> `importSingleAccount` 改为 `try await self.persistVault(derived)`，错误经 `runOperation` 映射为
> `.failure(.failure(...))`，不再写入账户元数据。新增 3 个回归测试
> （`testImportSingleAccount{FailsWhenVaultLocked,MnemonicBranchFailsWhenVaultLocked,SecretBranchFailsWhenVaultLocked}`），
> 断言 vault 锁定 → `.failure(.failure("vaultLocked"))` 且 store 无该账户；`AccountManagerTests` 20/20 通过。

`Sources/SwiftAccount/AccountManager.swift:272-291`（调用点 `:37`）

```swift
private func persistVault(_ derived: TraditionalDeriveResult) async {
    ...
    try? await self.vault.importMnemonic(...)   // vault 锁定/磁盘满/加密失败 → 静默
    ...
}
```

`importSingleAccount` 先 `persistVault(derived)` 再 `store.addAccount(walletAccount)`。vault 写入失败（如 `vaultLocked`、磁盘满、加密错误）时错误被 `try?` 吞掉，元数据照常入库并返回 `.success(id)` ——**账户存在但私钥从未落库**，用户后续将无法签名。

```swift
private func persistVault(_ derived: TraditionalDeriveResult) async throws { /* try await，去掉 try? */ }
// importSingleAccount 内：try await self.persistVault(derived)
```

### P0-6 SwiftDid：`verifyCredential` 过期校验 fail-open

> ✅ **已修复（2025-08-21）**：非空 `expirationDate` 改为先解析、解析失败直接
> `CredentialVerificationResult(verified: false, errorKind: "invalidExpirationDate")`（fail-closed），
> 不再跳过过期检查进入桥接验证。新增 2 个回归测试
> （`testVerifyCredentialMalformedExpirationFailsClosed` / `testVerifyCredentialFutureExpirationProceedsToBridge`），
> 畸形日期 → 不调桥直接失败、未来日期 → 仍正常调桥；`SwiftDidTests` 6 个 verifyCredential 用例全过。

`Sources/SwiftDid/SwiftDid.swift:517-522`

```swift
let expirationDate = DidJson.optString(credential, "expirationDate")
if !expirationDate.isEmpty,
   let date = DidJson.parseISO8601(expirationDate),   // 解析失败 → 跳过过期检查
   date < Date() {
    return CredentialVerificationResult(verified: false)
}
```

`expirationDate` 是**攻击者可控字段**；非空但无法解析（格式错误）时，过期校验被整体跳过，直接进入桥接验证。校验应 fail-closed：解析失败按「视为过期/校验失败」处理，或明确报 invalidPayload。

---

## P1 — 应该修复（按模块）

### SwiftDappConnect

| # | 问题 | 位置 |
|---|---|---|
| 1 | **SWTC 流程污染共享 ETH 链状态**：`handleSwtcRequestAccounts` 里 `ethMiddleware.setCurrentChain(.swtc)`，之后所有 ETH DApp 拿到 `eth_chainId = 0x1`，且 `eth_sendTransaction` 无显式 chainId 时直接报 "Chain swtc does not have an EVM chainId" | `WebAppInterface.swift:329-331`（配合 `EthMiddleware.swift:127-130,175-177`） |
| 2 | **`eth_accounts` 与 `eth_requestAccounts` 混同**：都走 `requestAccounts` 弹授权框；EIP-1193 规定 `eth_accounts` 静默返回已授权账户，DApp 加载时探测会误弹窗 | `WebAppInterface.swift:233-234` |
| 3 | **gas 估算失败静默回落 21000**：`estimateGas` 抛错（revert/余额不足/节点错误）时直接签 0x5208，合约调用会被签出并广播，白白烧 gas | `EthMiddleware.swift:158-166` |
| 4 | **`sendTransactionWithPassword` 丢弃密码**：参数 `password _: String` 被忽略，直接走可能命中 5s/20s 缓存的 `CachingSecretProvider`，API 承诺的认证强度与实现不符 | `SwtcMiddleware.swift:88-90` |
| 5 | **整条 RPC 管线绑死 MainActor**：`WebAppInterface`/`EthMiddleware`/`SwtcMiddleware`/`NodeProvider`/`NftProvider`/`WalletSigning` 全部 `@MainActor`，RPC 网络 I/O、签名、DID/IPFS 加密都在主线程，节点慢即卡 UI（`Interfaces.swift:20` 注释自认是「标 @MainActor 以通过 Swift 6 严格并发」） | 多个文件 |
| 6 | **`DAppConnectError` 非 `Sendable`** 却跨 actor 边界（`CachingSecretProvider` actor 内 `Task<String?, Error>`） | `model/Models.swift:16` |
| 7 | **`load*` 前缀误用**：`loadInitJs`/`loadAddressJs`/`loadUpdateChainIdJs`/`loadEip6963IconOverrideJs` 实际是生成 JS 字符串（只有 `loadProviderJs` 真读资源）；且 `WebAppInterface` 三个同名实例方法是 `DAppConnectSdk` 静态方法的透传，双入口 | `DAppConnectSdk.swift:80-132`、`WebAppInterface.swift:49-61` |
| 8 | **`route()` 约 120 行**：分发 + 参数提取 + 错误策略混在一个 switch；且 `handleEthSignTypedData` 收整个 request、其余 handler 收提取后的参数，风格不一 | `WebAppInterface.swift:202-323` |
| 9 | **每条消息在主线程 JSON 解析**（含大 NFT/DID payload） | `WebAppInterface.swift:105-109` |
| 10 | **`getChainId()` 与 `getCurrentChainIdHex()` 逐字节相同**，删一个 | `EthMiddleware.swift:63-66` vs `241-244` |
| 11 | `CachingSecretProvider`：`clearCache()` 后 in-flight 完成仍会回填缓存（锁屏后明文最多再服务 20s）；in-flight task 取消时未真正取消委托任务 | `CachingSecretProvider.swift:87-89,43-47` |
| 12 | `isSafeUrl` 正则弱：拒绝单标签 host（localhost）、接受非法端口、拒绝 IPv6、端口区间未锚定 → 改用 `URLComponents` 结构化校验 | `DAppConnectSdk.swift:137-140` |
| 13 | `failure(_:_:)` 对非 `DAppConnectError` 直接透传 `localizedDescription` 给页面（可能泄漏内部路径）；缺参错误用 -1 而非 EIP-1193 的 -32602 | `WebAppInterface.swift:615-624` |
| 14 | 死代码：`ChainConfigProvider` 定义但从未使用；`WebAppInterface.chainProvider` 只写不读；`DAppConnectError.missingParameters` 从未抛 | `Interfaces.swift:42-44`、`WebAppInterface.swift:18,79-84` |

### SwiftVault

| # | 问题 | 位置 |
|---|---|---|
| 1 | `changePassword` 重建 `newStore` 时**丢弃 biometric**（旧 store 的 biometric 未迁移） | `VaultRepository.swift:274-287` |
| 2 | **KDF 三重复制**：`verifyPassword`/`unlock`/`ensureUnlocked` 各自写一遍「derive + 常量时间比对」，派生的 key 被丢弃后 `unlock` 再派生一次 → 提取一个私有 `deriveAndVerifyKey` 助手 | `VaultRepository.swift:71-111,393-404` |
| 3 | 同步 Argon2（64–256 MiB 内存）在 actor 上执行，且 README 写的是 `try await`；应挪到后台或提供 async 变体 | `Argon2idVaultKeyDeriver.swift` |
| 4 | 导入路径 2–4 次全量 store load/save 往返（`importMnemonic`/`importSecret` 内部先调 `importPrivateKey` 再自己 load+append+save） | `VaultRepository.swift:128-168` |
| 5 | `importPrivateKeys` 重复导入静默 continue；`clearAllData(password: nil)` 无密码即清库（API 设计陷阱，调用方误传 nil 即免密清库） | `VaultRepository.swift:170-189,325-331` |
| 6 | `Wipe.swift` 全库无引用（生产死代码），`sessionKey` 从不主动擦除 | `util/Wipe.swift`、`VaultRepository.swift:13` |

> ⚠️ **更正（第二轮 pro 复核）**：第一轮曾把 `try store.keys.append(...)`（`:119,142,161,181,291,301,313`）判为「冗余 try」——**该结论错误**。`Array.append` 本身不抛错，但这些 `try` 覆盖的是**实参里的抛错调用**（`self.cipher.encrypt(...)`、`self.requireSessionKey()`、`keyDeriver.deriveKey(...)`），`VaultCipher.encrypt`/`VaultKeyDeriver.deriveKey` 均为 `throws`（`VaultCipher.swift:4-5`、`VaultKeyDeriver.swift:4`），故 `try` 是必要的。整库干净重编译**零告警**印证了这一点。

**SwiftVault 补充细节（第二轮审查新增，均验证）：**

- P0-1 的 `*Internal` 方法**被测试使用**（`VaultTests.swift:350,396,398`）且有文档说明是「刻意 public 但不稳定」（`Docs/Account-Swift/04-migration-and-testing.md:26`）→ 改 `private` 需配套把测试改为 `@testable import SwiftVault`（本包测试已是 @testable 风格，可安全收紧）
- **更正**：`VaultKeyDeriver`（及 `Argon2idVaultKeyDeriver`）非 `Sendable` 但存于 actor 内部——**这不是问题**（actor 隔离本就保护非 Sendable 状态；仅当跨越隔离边界时才需 Sendable）。干净编译确认无告警。
- **Wipe 的 Data COW 陷阱**：`sessionKey = key` 后对局部 `key` 做 `wipe()` 会因 COW 共享缓冲区**同时清零 store 里的 sessionKey**——擦除必须针对唯一持有者、在引用断开后进行；`Wipe.swift` 目前生产零引用（仅测试调用 `VaultTests.swift:429-449`）
- **README 与签名不符**：`Sources/SwiftVault/README.md:53-62` 文档写 `try await`，实际 API 是同步 `throws`（文档需修正或补 async 重载）
- 导入往返精确计数：`importPrivateKey` = 2 load + 1 save（`:114,118,125`）；`importMnemonic`/`importSecret` = 4 load + 2 save（`:135,137,141,150`）；`importPrivateKeys`（`:170-189`）已是正确的批量范式，前两者应改造成同款
- **篡改 store 文件的 KDF 参数 DoS**：`ProtobufVaultStoreDriver.swift:93-98` 直接信任文件内 `iterations`/`memoryKiB`，篡改后可令 `unlock` 分配数百 MiB × 多次 → 反序列化时 clamp 上限
- `TinkVaultCipher`：`registerAead` 每次调用重注册 + `@unchecked Sendable` 下可变 `cachedHandle`（`TinkVaultCipher.swift:6,10,33-42`）
- 锁定态信息面：`hasPassword`/`listAccounts`/`addressInKeys`/`hasBiometric` 等元数据 API 在锁定时即可应答（`:41,191,195-205,207`），P3
- `VaultKeyDeriver` 及实现非 `Sendable` 却存于 actor（Swift 6 下应补 `Sendable` 或 `@unchecked`）

### SwiftAccount

| # | 问题 | 位置 |
|---|---|---|
| 1 | `importSubAccount` 以 `Keypair(privateKey: "", ...)` 走 `importSingleAccount` → `persistVault` 会 `importPrivateKey(address, Data())` 加密**空私钥**（当前仅因 `VaultRepository.importPrivateKey` 判重短路才没出事）→ 加 `persistKey: Bool` 参数 | `AccountManager.swift:144-164,289` |
| 2 | **`removeAccount` 同名陷阱**：`SwiftAccount.removeAccount(accountId:)` 是裸 store 删除（不验密、不清理 vault），`AccountManager.removeAccount(accountId:password:)` 才是编排删除——同名异构行为，走门面会静默遗留 vault 密钥 | `SwiftAccount.swift:67-69` vs `AccountManager.swift:232-250` |
| 3 | `removeAccount` 双重 Argon2：先 `verifyPassword` 再 `removeAddress` → `ensureUnlocked` → `unlock` 再派生一次 | `AccountManager.swift:237,246` |
| 4 | `SwiftAccount` 是 `AccountStore` 的 ~26 个方法纯透传（零逻辑），会随协议漂移 → 直接暴露 `store` 或让门面 conform `AccountStore` | `SwiftAccount.swift:29-131` |
| 5 | `deriveSubAccount` 连续两次相同 `findById`（第一次 guard 是死代码） | `AccountManager.swift:177-182` |
| 6 | `(try? findNonRootAccount(...)) != nil` 占用探测：store 出错按「未占用」处理，反而继续派生该 index | `AccountManager.swift:201` |
| 7 | 无 `(address, chain)` 唯一索引：预检 + 插入非原子，并发导入同地址会重复入库 | `GRDBAccountStore.swift:23-34` |
| 8 | 观察流出错时静默 `finish()`，消费方无法感知流死亡 | `GRDBAccountStore.swift:283-284` |
| 9 | UPDATE 方法不检查影响行数（更新不存在的 id 静默成功，Kotlin Room `@Update` 有行数返回） | `GRDBAccountStore.swift:142-173` |

### SwiftNft

| # | 问题 | 位置 |
|---|---|---|
| 1 | **SSRF 守卫不覆盖返回给宿主的 URL**：恶意元数据 `image: "http://192.168.1.1/..."` 会被模块原样交给宿主加载器，宿主若不复检即被 SSRF | `SwiftNft.swift:358-408` |
| 2 | 注入自定义 `URLSession` 时 GET 会**静默跟随重定向**（no-redirect 策略只在默认 client 生效）→ 每个请求显式 `httpShouldFollowRedirects = false` | `NftHttpClient.swift:39-45` |
| 3 | `removeAll()` 后完成的 fetch 会回填缓存（generation counter 修复） | `NftMetadataImageCache.swift:36-49,60-67` |
| 4 | **`LOWER(ownerAddress)` 使 `swtc_nfts.ownerAddress` 索引失效**（全表扫描）+ 大小写混合写入；`issuer` 无索引 | `GRDBNftStore.swift:147-153,176` |
| 5 | `deleteSwtcNftsByOwner` 循环内逐条查询 → N+1 | `GRDBNftStore.swift:213-218` |
| 6 | `SELECT *` 拉取可数 MB 的 `fullContent` 列 | `GRDBNftStore.swift` |
| 7 | `eth_call` 无记忆化：同一 tokenURI 反复 `fetchRpc` | `EthTokenUriResolver.swift` |
| 8 | SSRF 残余缺口：NAT64 `64:ff9b::/96`、Teredo `2001::/32`、`2001:db8::/32` 文档段未拦截；DNS rebinding TOCTOU 已在注释中承认 | `SsrfGuard.swift:132-162` |
| 9 | `String` 用 `index(_:offsetBy:)` 做随机访问下标（`EthTokenUriResolver.swift:128-134`），O(n²) 且 `offsetBy: range.count` 在超界时可能越界 | `EthTokenUriResolver.swift` |

**SwiftNft 补充细节（第二轮审查新增，均验证）：**

- **SSRF 守卫补充缺口**：NAT64 `64:ff9b::/96` 与 IPv4-translated `::ffff:0:0:0/96` 内嵌私网 IPv4 可绕过（如 `64:ff9b::7f00:1` → 127.0.0.1）；`192.88.99.0/24`（6to4 relay）未拦；建议对最后 32 位为点分四段的 IPv6 按 IPv4 分类 + 显式拦 `64:ff9b::/96` | `SsrfGuard.swift:132-162`
- `canonicalizeHttpIpfsUrl` 路径穿越味：`https://evil.com/ipfs/../../etc/passwd` → `gateway + "../../etc/passwd"`（仍在可信网关 host 上，非 SSRF，但应剥 `../` 段） | `NftUrlUtils.swift:106-115`
- `data:image/svg+xml` 放行：注释已警告 SVG 可含脚本——宿主必须用 `UIImage/CGImage` 渲染、禁止 `WKWebView`（建议在 API 文档显式声明） | `NftUrlUtils.swift:37-40`
- **`SwtcTokenUriResolver.gateway` 是 `public var`**（`Sendable` struct 上可变，但无人写）→ 改 `let`；且其 init 只做尾斜杠归一化、缺 http(s) scheme 校验（与 `SwiftNft.swift:47-51` 不一致） | `SwtcTokenUriResolver.swift:18,30`
- 死代码：`SwiftNft.swift:53` 的非法网关告警永远不触发（`self.ipfsGateway = resolved.ipfsGateway` 后再比较 `self.ipfsGateway != resolved.ipfsGateway` 恒 false）→ 与原始 `config.ipfsGateway` 比较
- `fetchMetadataFields` 静默返回 `.empty` 且无日志（与 `fetchAndCacheNftMeta` 的 `logFailure` 不一致）| `SwiftNft.swift:224-230`
- `resolveEthrAvatar` 无 `chainId` 时 `?? 0` → `"0x0"` 查库 + `getRpcNode(0)`（应视为 unknown 跳过 DB 查询）；VC issuer 大小写未归一化导致 `nft_meta` 精确匹配落空 | `SwiftNft.swift:148,165-169`、`GRDBNftStore.swift:122-127`
- `buildCredentialAssetKey` 末尾 `return "image:\(trimmed)"` 仅在全部字段为空时可达 → 恒定键 `"image:"`；`:427/433` 的 `normalized!` 安全但应改 `??` | `SwiftNft.swift:412-436`
- `ValueObservation` 无 `distinctUntilChanged` 每次写都重发；`AsyncStream` 默认无界缓冲；观察出错静默 `finish()` 无日志 | `GRDBNftStore.swift:392-406`
- `getaddrinfo`（阻塞系统调用）在协作线程池内同步执行且每次 fetch 检查两次（facade + `ssrfAllowed`）；`NftHttpClient` 默认 client 持有两个 `URLSession` 实例（GET no-redirect + RPC follow-redirect）| `SsrfGuard.swift:38-58`、`NftHttpClient.swift:47-56`
- 命名：`Url`→`URL`（`normalizeRemoteAssetUrl`/`isLoadableRemoteAssetUrl`/`resolveRemoteImageUrl` 等 10+ 处）、`get*` 前缀（`getNftMeta`/`getSwtcNftByIssuerAndTokenId`）、`observe*` vs `getNftCollectionsFlow` 不一致、`decodeHexToUtf8`/`optString` org.json 风格 | `NftUrlUtils.swift`、`NftStore.swift:14-40`

### SwiftDid

| # | 问题 | 位置 |
|---|---|---|
| 1 | 8 个公开写 API 全部 `catch { return false / DidWriteResult(success: false) }`：校验失败与传输失败不可区分、零日志，联调只能靠猜 | `SwiftDid.swift:262-509` |
| 2 | `start()` 只对具体类型 `WebviewBridgeEngine` 调 `engine.start()`，`destroy()` 走协议 `bridge.destroy()` —— 协议里没有 start，类型判断破坏抽象 | `SwiftDid.swift:64-79` |
| 3 | `buildGenerateVcParams` 校验失败返回空字典 `[:]`，空参继续调桥接 `generateVC`（静默失败、错误信息全丢）→ 应抛错 | `SwiftDid.swift:819-835` |
| 4 | `SwiftDidError` 部分 case 从未抛出（死代码）；门面 866 行，建议拆分 | `SwiftDid.swift` |
| 5 | `formatUtc`/`parseISO8601` 每次新建 `ISO8601DateFormatter`（创建开销大）；建议 `Date.ISO8601FormatStyle`（Sendable、免分配） | `DidJson.swift:89-124` |

**SwiftDid 补充细节（第二轮审查新增，均验证）：**

- 全库唯一强制解包：`DidCoreService.swift:89` `chainUpdated > localUpdated!`（`||` 短路保护，安全但脆弱）→ 改 `guard let` 或 `localUpdated.map { chainUpdated > $0 } ?? true`
- GRDB 缺索引：`observeAll` 每次变更全表扫描 + `ORDER BY updatedAt DESC`；`deleteExpiredPending` 的 `updatedAt < ?` 无索引 → v1 迁移补 `did_documents(updatedAt)` / `did_pending(updatedAt)` 索引
- 死代码：`SwiftDidError.notInitialized` / `didNotFound` 从未抛出；`DidJson.isBlank` 无调用（与 `DidCredentialHelper.isBlank`、`nilIfBlank` 共三份空白判断，合并留一份）
- 重复实现：`DidDocumentEditor.credentials(from:)` 与 `DidCredentialHelper.readCredentials` 逐字相同（应互调）；`previousCid` 变换出现 3 次（`updateDidNickname`/`updateDidAvatar`/`applyPreviousCid`）→ 抽 `updatingIpfsStoragePreviousCid(in:previousCid:)`
- `loadPending` 主键 `(kind, did)` 唯一却返回 `[DidPending]`（调用方都用 `.first`）→ 协议应返回 `DidPending?`
- 访问控制：`Keccak256`/`ChecksumUtils`/`BridgeDidResolver`/`DidCoreService` 均 `public` 但仅模块内使用（测试用 `@testable`）→ 收紧为 `internal`；`GRDBDidStore` 的 `@unchecked Sendable` 可尝试去掉（`DatabasePool` 本身 Sendable）
- 其他：`queryAndValidateVcid` 用 `try?` 丢弃桥接错误通道（`SwiftDid.swift:452`）；`generateProfileVC` 忽略 `credential` 别名（`:168`）；`isSelf` 未处理多 controller 空格分隔（`:158`）；`updateDidAvatar` 更新后 credential 数组重排（`:366-371`）

### SwiftWallet

| # | 问题 | 位置 |
|---|---|---|
| 1 | `buildSwtcNftTransfer` 解析失败返回 `[:]` 吞错：下游 `SwtcMiddleware` 只注入 Sequence 就签名 → 应 throw 带描述的错误 | `SwiftWallet+WalletSigning.swift:42-51` |
| 2 | `WalletModels.swift:56` `accounts: [SubWallet] = []` 默认值对合成 `Decodable` 无效，JS 缺 `accounts` 键直接 `keyNotFound` → 自定义 `init(from:)` + `decodeIfPresent ?? []` | `WalletModels.swift:56` |
| 3 | `SwiftWalletError` 缺 `Sendable`；`buildSwtcNftTransfer` 与类内同名方法仅返回类型不同（易混淆） | `SwiftWallet.swift:239` |

### SwiftWebviewBridge（P1 部分）

| # | 问题 | 位置 |
|---|---|---|
| 1 | in-flight `evaluateJavaScript` Task 无追踪、不随超时/`destroy()` 取消：JS 卡死则任务强持 client+runtime 直到进程结束 | `WebviewBridgeClient.swift:109-116` |
| 2 | `resetReady()` 静默丢弃 ready-waiters → 等待方挂到超时 | `PromiseGateway.swift:102-105` |
| 3 | `UInt64(timeoutMs * 1_000_000)`：负值/NaN/Infinity → 运行时 trap；亚毫秒截断 | `PromiseGateway.swift:42,75` |
| 4 | `WebviewBridgeConfig.resourceBundle` 死配置（实际只用 `bundle:` 参数） | `WebviewBridgeConfig.swift:13,20` |
| 5 | `parseResult` 中 `guard object["result"] != nil` 之后的 `guard let result = object["result"]` 是不可达代码（`{result: null}` 产出 NSNull 非 nil） | `PromiseGateway.swift:145-147` |

---

## 命名规范问题（Swift API Design Guidelines 专项）

1. **`get` 前缀泛滥**（应删）：`EthMiddleware.getChainId/getBlockNumber/getAccountsForChain/getCurrentChainIdHex`、`SwtcMiddleware.getPublicKey`、`WebAppInterface.getPrivateKeyOrFail`、`VaultRepository.get()`（与 `static let shared` 重复）、`AccountStore.getCurrentAccountId/getMaxIndexByChain/getSameAccountsCount`、`NftProvider.getRpcUrl/getTransactionCount/getGasPrice/getEvmNfts/getSwtcNfts`、`WalletSigning.getEncryptionPublicKey`。
2. **`load*` 误用**：`DAppConnectSdk.loadInitJs/loadAddressJs/loadUpdateChainIdJs/loadEip6963IconOverrideJs` 是生成 JS 字符串，`load` 暗示读资源 → 建议 `initJavaScript(chainIdHex:rpcUrl:token:)`、`setAddressJavaScript(...)` 等。
3. **大小写不一致**：`WebviewBridgeClient/WebviewBridgeConfig/WebviewBridgeEngine/WebviewBridgeError` vs `WebViewRuntime`；`callJsMethod` 的 "Js" vs "JS"。
4. **三层命名同一操作**：`WebviewBridgeClient.callJsMethod` vs `EngineBridge.call/callAs`；`callAs` 的 `as:` 标签与关键字撞名 → `callTyped(asType:)`。
5. **`Hd` → `HD`**：`importHdWallet`/`hdResult:`/`rootHDAccounts`。
6. **标签冗余**：`hdWalletFromMnemonic(mnemonic:)`、`deriveFromMnemonic(mnemonic:)`、`updateParentId(accountId:parentId:)`。
7. **同操作不同名**：`ContinuationBox.resume` vs `ReadyWaitBox.resumeIfPending`；`PromiseGateway` 内 `onPromiseResult/register/finish/remove` 四动词。
8. **`route()` / `WebAppInterface` 672 行**：按域拆 `routeSwtc/routeEth/routeDidNft`，把参数提取下沉到各 handler。
9. `handleEthSignTypedData` 收整个 `request` 与其余 handler 收提取参数的风格不一致。

---

## 性能优化专项

> 按收益排序；标注了「已实测/静态推断」，避免误导性优化。除注明外均为静态分析结论，
> 上线前建议用 Instruments 对热点路径复核。
> **实施状态（2025-08-22）**：✅ = 已落地并测试通过；未标 = 待办。

### A. 字符串 / 编码热路径

1. ✅ **已实现**：逐字节 `String(format: "%02x")` hex 编码（3 处 + 1 处手写 nibble）——
   `SwiftCore.Hex`（encode/decode 查找表）已落地并替换全部调用点，新增 4 个单元测试：
   - `WebAppInterface.makeResponseToken`（`WebAppInterface.swift:63-66`）
   - `Keccak256.hex`（`Keccak256.swift:73-75`，大 data 时开销显著）
   - `EthTokenUriResolver.buildTokenUriCallData`（`EthTokenUriResolver.swift:63`）
   - `ChecksumUtils.toChecksumAddress`（`ChecksumUtils.swift:23-30` 手写 nibble，且每字符 `uppercased()` 分配 + 每调用重编译正则 `:16`）

   ```swift
   enum Hex {
       private static let digits = Array("0123456789abcdef".utf8)
       static func encode(_ bytes: [UInt8]) -> String {
           var out = [UInt8](); out.reserveCapacity(bytes.count * 2)
           for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0F)]) }
           return String(decoding: out, as: UTF8.self)
       }
   }
   ```

2. ✅ **部分已实现**：O(n²) String `index(_:offsetBy:)` 随机访问（3 处）——`ChecksumUtils.swift:25`
   已改 UTF-8 字节迭代；`NftUrlUtils.swift:220-224` 与 `EthTokenUriResolver` 内联循环已随
   `Hex.decode` 移除；`EthTokenUriResolver.swift:128-134` 的 String subscript 扩展保留（仅内部
   使用、调用点均有界长 guard，可后续清理）。

3. **`ISO8601DateFormatter` 每次新建**（`DidJson.swift:102-124`、`SwiftDid.formatUtc`）——创建开销大；`Date.ISO8601FormatStyle` 为 Sendable、零分配，可替代（iOS 15 起可用）。

4. **已核实「非热点」，无需优化**（避免过度工程）：`Path.derivationPath` 插值（每次导入/派生仅 1 次，非循环内）；`boolFromRaw`（trim+lowercase，每 RPC 一次）；`ChainType.fromBip44Code` 线性扫描（N=7，static dict 仅在枚举膨胀时值得）。

### B. 加密 / 哈希

1. ✅ **已实现**：Keccak absorb 逐字节组装 UInt64 lane（`Keccak256.swift:47-51`）——改为
   `withUnsafeBytes` + `loadUnaligned` 按 8 字节 lane 读入（每块 17 次 lane 异或取代 136 次
   div/mod + 移位），KAT 10/10（含长消息多块向量）验证哈希一致。
2. **`permute` 每次调用重新分配 `c/d/b` 三个 25 元素数组**（`Keccak256.swift:78-80`，非每轮分配——24 轮复用同一批）；32 字节输入仅 1 次 permute，收益有限，可接受或提升到 `hash()` 复用。
3. **Argon2 重复派生**：`AccountManager.removeAccount`（`verifyPassword` + `unlock` 两次完整 64 MiB KDF）；`VaultRepository.verifyPassword`/`unlock`/`ensureUnlocked` 三处重复实现且已解锁分支仍重算 → 提取 `deriveAndVerifyKey` 助手，单次派生复用。
4. ✅ **已实现**：随机数生成——`VaultRepository.randomData` 改 `SecRandomCopyBytes`
   （密码学安全源 + 批量生成，替代逐字节 `UInt8.random`，`VaultRepository.swift:426-432`）。

### C. 存储 / GRDB

1. **`LOWER()` 使列索引失效（全表扫描）**：`LOWER(address)`（`GRDBAccountStore.swift:151,194,204,214,225,264` 配 `idx_accounts_address`）、`LOWER(ownerAddress)`/`LOWER(issuer)`（`GRDBNftStore` swtc 表）、EVM 表查询中的 `LOWER()`（`GRDBNftStore.swift:250,263,298…`）→ 写入时归一化小写 + 查询去 `LOWER()`，或建表达式索引；EVM 表写入已小写（`GRDBNftStore.swift:285-286`），swtc 表写入未小写（`:176`，不一致）。
2. **`SELECT *` 拖回多 MB `fullContent`**（`GRDBNftStore.swift:122-127` 等头像查询）→ 投影所需列（contract/tokenId/name/image/tokenUri/updatedAt）。
3. **N+1：`deleteSwtcNftsByOwner`**（`GRDBNftStore.swift:213-218`）逐行查 `nft_meta` → 每 owner 一次批量查询 + 内存字典。
4. **缺索引**：`swtc_nfts.issuer`（`GRDBNftStore.swift:185-193` 按 issuer 查无索引）；`did_documents(updatedAt)` / `did_pending(updatedAt)`（`GRDBDidStore.swift:45-49` 全表扫描排序、`:119-126` TTL 删除无索引）→ v1 迁移补。
5. **ValueObservation 每次写都重发射**（无 `distinctUntilChanged`，`GRDBNftStore.swift:392-406`）+ `AsyncStream` 默认无界缓冲 → `.removeDuplicates()` + 明确 bufferingPolicy。
6. **Vault 全量 load/save 往返**：`importPrivateKey` = 2 load + 1 save；`importMnemonic`/`importSecret` = 4 load + 2 save（`VaultRepository.swift:114-168`）；`importHdWallet` 对 N 子账户累计 O(N) 次全量重写 → 按 `importPrivateKeys`（`:170-189`）批量范式改造。
7. `observeCurrentAccount` 每 tick 2 查询（`GRDBAccountStore.swift:54-57`）——单读事务一致快照，非 N+1，可接受（记录在案）。

### D. 网络

1. **`eth_call` 无记忆化**：`EthTokenUriResolver.resolveEthrTokenUri`（`EthTokenUriResolver.swift:33-37`）每次发 `fetchRpc`，`SwiftNft.resolveEthrAvatar` 缺 tokenUri 时重复调用（`SwiftNft.swift:154-156,170-172`）→ 按 `(chainId, contract, tokenId)` 加小 LRU + in-flight 去重（复用 `NftMetadataImageCache` 模式）。
2. **双 IPFS 归一化**：`EthTokenUriResolver.normalizeTokenMetadataUri` 用默认网关（`EthTokenUriResolver.swift:99-102`），门面再按配置网关归一一次（`SwiftNft.swift:498-501`）→ 给前者加 `gateway` 参数，单次归一。
3. **VC 逐字段重复 JSON 解析**：`SwiftNft.readString` 每个字段重新 `JSONSerialization`（`SwiftNft.swift:100-104` 调 4 次、`:146-149` 调 3 次）→ 先 parse 一次成 `[String: Any]` 再读字段（SwiftDid 已有同款优化模式）。
4. **`getaddrinfo` 阻塞系统调用在协作线程池**（`SsrfGuard.swift:38-58`）且每次 fetch 双次 SSRF 检查（`NftHttpClient.swift:69,79` + 门面 `SwiftNft.swift:193,226,300,394`）→ 并发增长时移出线程池；检查收敛为单点。
5. **默认 client 持有两个 `URLSession` 实例**（`NftHttpClient.swift:47-56`：no-redirect + RPC 各一）→ 跨门面/实例复用 session（配置可共享）。
6. ✅ **已实现**：`loadProviderJs` 每次调用重读 bundle 资源 + 全文件 `replacingOccurrences`
   （`DAppConnectSdk.swift:82-83`）→ 模板改 `static let` 缓存，仅替换 token。

### E. 主线程 / 每调用开销

1. **DAppConnect 每条消息主线程 `JSONSerialization`**（`WebAppInterface.swift:105-109`，含大 NFT/DID payload）→ `Task.detached` 或仅对大数据异步化。
2. **PromiseGateway 每调用 3 个 Task + UUID + box + checked continuation**（`PromiseGateway.swift:41-45`、`WebviewBridgeClient.swift:86-132`）；`parseResult` 对非字符串结果先解析再反序列化（双程，`PromiseGateway.swift:152-155`）；`JSONDecoder` 每调用新建（`WebviewBridgeClient.swift:172`）→ 合并为单个可追踪 Task（同时修复 1.3 悬挂）、复用 `JSONDecoder`。
3. **每条 console 消息主线程 `NSLog`**（`WebviewBridgeClient.swift:304`）→ DEBUG 开关。
4. `NftMetadataImageCache`（LRU 256 上限 + per-key in-flight 去重）**设计正确，保持**；仅 `removeAll()` 后回填竞态需 generation counter（正确性 P1，非性能）。

### F. 待量化（收益需 Instruments 确认）

- 主线程 `deliver` 的 JSON 序列化 + `jsQuote` 双程全串拷贝（`WebAppInterface.swift:182-198`）
- `swtcNftJson`/`ethNftJson` 逐条 `[String: Any]` 构建（`WebAppInterface.swift:630-671`）
- `String(describing: result)` 兜底序列化（`PromiseGateway.swift:156`，NSNumber 时与 locale 相关）

---

## 打包/工程问题

> ✅ **已修复（2025-08-22）**：7 个含 README 的 target（SwiftCore / SwiftVault / SwiftWebviewBridge /
> SwiftDappConnect / SwiftNft / SwiftDid / SwiftAccount）在 `Package.swift` 加
> `exclude: ["README.md"]`，SwiftPM "found 1 file(s) which are unhandled" 告警归零（构建实测
> 0 warning / 0 error）；`Sources/` 下磁盘上的 `.DS_Store` 已删除（本就已被 .gitignore 忽略）。
> `Sources/SwiftVault/proto/private_key_vault.proto` 经核实由 SwiftProtobufPlugin 消费，不产生告警，无需改动。

- **7 条构建告警**：各模块 `Sources/<Module>/README.md` 未在 `Package.swift` 声明为资源或 exclude（SwiftPM 告警 "found 1 file(s) which are unhandled"）→ 已加 `exclude: ["README.md"]`（不移文件，保持模块内 README 约定与代码注释中的路径引用有效）。
- `Sources/` 下存在 `.DS_Store` 文件（应 .gitignore / 删除）→ `.gitignore` 已有条目（未跟踪）；磁盘文件已清理。

---

## 做得好的地方（保持）

1. **Swift 6 并发纪律优秀**：`@MainActor` 边界、actor 选择、跨 actor 的 `await` 设计整体正确；全库**零强制解包 / 零 `try!` / 零 fatalError**。
2. **SwiftVault**：actor 隔离、按记录类型区分 AAD、常量时间比对、HMAC proof 带域分隔符、sessionKey 设置顺序正确——密码学工程意识在线。
3. **SSRF 守卫**（`SsrfGuard.swift`）：DNS fail-closed、全地址解析、IPv4-mapped IPv6、CGNAT/ULA/link-local 覆盖全面，且把残余 TOCTOU 显式写入注释。
4. **CachingSecretProvider**：actor + per-key in-flight 去重 + 桥接窗口/绝对上限设计正确（仅 P1 的 clearCache 回填与取消遗留）。
5. **GRDB 使用**：`DatabasePool`、单事务批量写、ValueObservation + onTermination 取消、upsert 语义克制（只用于固定单行）。
6. **DeriveGate**：链式 Task 实现异步互斥，正确规避了 NSLock 跨 await 与 actor 重入两个陷阱。
7. **桥接层**：`;null` 结尾规避 WebKit Promise 序列化坑、token 鉴权、主 frame + securityOrigin 实时推导的 origin 策略、弱引用纪律（无 retain cycle）。
8. **Kotlin 对齐文档**：几乎所有偏离/对齐点都有坑号注释（04 坑 #N），可追溯性极佳。
9. **SwiftCore 模型收敛**：Path/ChainType/WalletAccount 去重合并完成、无残留重复定义。

---

## 建议行动顺序

1. **P0 六项**（1-2 天）：~~Account persistVault 改 throws~~（✅ 已修复，见 P0-5）→ ~~Did 过期校验 fail-closed~~（✅ 已修复，见 P0-6）→ ~~Nft 溢出界长~~（✅ 已修复，见 P0-4）→ ~~Bridge 跨线程 double-resume~~（✅ 已修复，见 P0-2）→ ~~Bridge clearAll 悬挂~~（✅ 已修复，见 P0-3）→ Vault 内部方法改 private。
2. **P1 高价值**：DappConnect 的 currentChain 污染（#1）+ `eth_accounts` 静默化（#2）+ 管线移出 MainActor；Account 的 removeAccount 同名陷阱 + 空私钥路径；Vault 的 KDF 去重 + biometric 迁移。
3. **性能批**：hex 工具合并、Keccak lane 读入、GRDB 表达式索引、主线程 JSON 异步化。
4. **命名批**：`get*`/`load*`/`Webview` 大小写/`Hd` 统一（API 破坏性改动，建议与下一主版本号一起发）。
5. 补测试：Account 空私钥。

---

## 修复记录

- **性能/去重批（2025-08-22）**：SwiftCore 新增 `Hex`（encode/decode 查找表，4 个单元测试）与
  `AsyncSequence.firstValue()`；替换 4 处 hex 编码 + 2 处 hex 解码调用点；ChecksumUtils 改 UTF-8
  字节迭代（消除 O(n²) 索引）；Keccak absorb 改 lane 读入（KAT 10/10）；`randomData` →
  `SecRandomCopyBytes`；`loadProviderJs` 模板缓存；`jsQuote` 合一；Vault AAD 三合一；SwiftDid
  `previousCid` 变换 ×3 / credentials 读取 / 凭据查找去重。5 模块 234 测试 + SwiftCore 11 测试全过。
- **打包/工程（2025-08-22）**：`Package.swift` 为 7 个含 README 的 target 加 `exclude: ["README.md"]`，
  SwiftPM unhandled 告警归零（构建实测 0 warning / 0 error）；`Sources/` 磁盘 `.DS_Store` 已清理。
- **P0-3（2025-08-22）**：`PromiseGateway.clearAll()` 恢复 pending 调用者——先取走全部 pending、
  清空表，再逐个取消超时任务并以 `.webViewUnavailable` 回调（destroy 中途的 `callJsMethod`
  不再永久悬挂）。新增 2 个回归测试（网关层 `test_clearAll_resumesPendingCallbacksWithError`、
  客户端层 `test_callJsMethod_destroyWhileInFlight_resumesWithError`），`SwiftWebviewBridgeTests` 45/45 通过。
- **P0-2（2025-08-22）**：SwiftWebviewBridge 跨线程 double-resume 修复——两处 `onCancel` 跳回主线程
  （`callJsMethod` 的 resume、`waitForReady` 的 `box.cancel()`），`ContinuationBox` 加 `NSLock`
  （`install`/`take` 原子化）作纵深防御。新增 3 个回归测试（box 并发双路 resume 确定性用例 +
  两个后台线程取消的客户端级用例），`SwiftWebviewBridgeTests` 43/43 通过。
- **P0-4（2025-08-21）**：`EthTokenUriResolver.decodeAbiString` 整数溢出修复——`length` 在乘法前先按
  剩余数据量界住（`length <= (normalized.count - 128) / 2`），恶意合约的 2^62..<2^63 长度字不再
  触发 `length * 2` 溢出崩溃。新增 2 个回归测试（2^62 / 2^63-1 溢出临界值 → nil、
  length=可用数据长度边界 → 正常解码），`EthTokenUriResolverTests` 18/18、`SwiftNftTests` 129/129 通过。
- **P0-5（2025-08-21）**：`AccountManager.persistVault` 改为 `async throws`，`try?` 全部改为 `try await`；
  `importSingleAccount` 同步 `try await`，错误经 `runOperation` 映射为 `.failure`，不再出现「账户成功但私钥未入库」。
  新增 3 个回归测试（vault 锁定 × privateKey/mnemonic/secret 分支），`AccountManagerTests` 20/20 通过。
- **P0-6（2025-08-21）**：`SwiftDid.verifyCredential` 过期校验 fail-open 修复——非空 `expirationDate`
  解析失败即返回 `verified: false, errorKind: "invalidExpirationDate"`（fail-closed），不再跳过过期检查。
  新增 2 个回归测试（畸形日期 fail-closed / 未来日期正常调桥），`SwiftDidTests` 6 个 verifyCredential 用例全过。

---

*评审基于 commit 9d6286e（2025-08-21）；P0-2 / P0-3 / P0-4 / P0-5 / P0-6 修复已落地（见修复记录与 git log）。*

---

## 附录：第二轮 Pro 复核（跨模块 + 编译验证）

> 方法：① 强制干净重编译全部目标（`touch` 全部 Sources/*.swift 后 `swift build`），在 Swift 6 严格并发（swift-tools 6.2 默认开启）下采集真实编译告警/错误；② 跨模块横向 grep + 逐点核对。**未修改任何源码。**

## 一、编译验证结果（新增，最有价值）

**整库 Swift 6 严格并发下干净重编译 = 0 warning / 0 error**（仅剩 7 条"模块 README 未声明资源"的打包提示）。

由此带来的两处**对第一轮结论的更正**：

1. ~~VaultRepository 7 处 `try store.keys.append(...)` 冗余~~ —— **错误**。`try` 覆盖的是实参中的抛错调用（`cipher.encrypt`/`requireSessionKey`/`deriveKey`，均为 `throws`），是必要的。
2. ~~`VaultKeyDeriver` 非 Sendable 存于 actor 是问题~~ —— **错误**。actor 隔离保护非 Sendable 状态，属正常用法。

同时说明：第一轮子代理标注的「`DAppConnectError`/`SwiftWalletError` 缺 Sendable 跨 actor 边界」在**当前代码路径下不构成编译错误**（这些错误在跨隔离边界前已被本地 catch），属**前瞻性/未来维护**项而非现存缺陷——因此其优先级应降为 P2，而非 P1。

## 二、跨模块重复实现（按模块审查会漏掉的部分）

### 2.1 跨模块重复（应收敛到 SwiftCore / 公共 util）

> 实施状态（2025-08-22）：✅ = 已去重；未标 = 待办。

| 重复项 | 出现位置 | 建议 |
|---|---|---|
| ✅ **hex 编码 `String(format: "%02x")` 逐字节** | `Keccak256.swift:74`、`WebAppInterface.swift:65`、`EthTokenUriResolver.swift:63` + `ChecksumUtils.swift:23-30`（手写 nibble，第 4 种） | 已收敛到 SwiftCore `Hex.encode`（查找表版）+ 4 个单元测试 |
| ✅ **hex → bytes 解码** | `NftUrlUtils.decodeHexToUtf8`（`NftUrlUtils.swift:210-227`）、`EthTokenUriResolver` 内联循环（`:83-92`） | 已收敛到 SwiftCore `Hex.decode`，两处共用 |
| **`optString` JSON 标量取值** | `DidJson.swift:25`、`NftUrlUtils.swift:170`（同签名、不同默认值语义） | 合一（统一 `default:` 参数） |
| **`isBlank` 空白判断** | `DidJson.swift:47`（死代码）、`DidCredentialHelper.swift:193`、`NftUrlUtils.swift:248` | 合一，删死代码 |
| **`nilIfBlank`** | `NftUrlUtils.swift:241-245`（public String 扩展）、`SwiftDid.swift:862-866`（private String 扩展） | 合一（放 SwiftCore String 扩展） |
| ✅ **`firstValue()` AsyncStream 取首元素** | `SwiftDappConnect/AsyncSequence+First.swift:6`、`SwiftNft/SwiftNft.swift:508` | 已收敛到 SwiftCore `AsyncSequence.firstValue()`（删 DappConnect 重复文件 + SwiftNft 私有实现） |
| **嵌套 JSON 路径读取 `readString`/`readValue`** | `SwiftNft/SwiftNft.swift:450,475`、`SwiftDid/SwiftDid.swift:612,637`（逐字同款 `$.` 剥离 + 点分路径遍历） | 合一 |
| ✅ **O(n²) String `index(_:offsetBy:)` 随机访问** | `ChecksumUtils.swift:25`、`NftUrlUtils.swift:220-224`（`decodeHexToUtf8`）、`EthTokenUriResolver.swift:128-134`（subscript 扩展） | ChecksumUtils 已改 UTF-8 字节；后两处随 `Hex.decode` 移除内联循环（subscript 扩展保留待清） |
| ✅ **`jsQuote` JS 字符串转义** | `DAppConnectSdk.swift:169-176`、`WebAppInterface.swift:191-198`（逐字相同） | 已提为 `DAppConnectSdk.jsQuote`（internal），WebAppInterface 复用 |
| **地址相等语义（4 种实现）** | `VaultRepository.normalizedAddress`（lowercased）、GRDB `LOWER(address)`、`EthMiddleware` `caseInsensitiveCompare`、`WebOrigin.normalize`（小写+去默认端口） | 收敛为「存储层统一小写 + 比较层规范化后相等」（详见「四、架构层观察 #2」） |

### 2.2 模块内跨文件重复（同模块不同文件，单文件审查易漏）

| 重复项 | 出现位置 | 建议 |
|---|---|---|
| ✅ **`previousCid` 变换 ×3** | `SwiftDid.swift:318-332`（updateDidNickname）、`:351-365`（updateDidAvatar）、`:768-782`（applyPreviousCid）——三处都在 map 闭包内重建 `IpfsStorage` service | 已抽 `DidDocumentEditor.serviceWithPreviousCid(did:service:previousCid:)`，三处复用 |
| ✅ **credentials 读取别名逻辑** | `DidDocumentEditor.credentials(from:)`（`DidDocumentEditor.swift:44-47`，注释自认镜像）vs `DidCredentialHelper.readCredentials`（`DidCredentialHelper.swift:128-131`）——同款 `credentials`/`credential` 双键回退 | 已抽 `DidCredentialHelper.credentials(in:)`，`readCredentials` 与 editor 共用 |
| ✅ **凭据查找** | `SwiftDid.findCredentialById`（`SwiftDid.swift:660-668`）vs `DidCredentialHelper.findCredentialIndex`（`DidCredentialHelper.swift:133-138`，`DidDocumentEditor.swift:70` 已在用） | 门面已复用 `findCredentialIndex` + `DidJson.stringify` |
| ✅ **AAD 前缀拼接 ×3** | `VaultRepository.addressAAD`/`mnemonicAAD`/`secretAAD`（`VaultRepository.swift:410-420`，三份 `"前缀:lowercased(address)"`） | 已收成 `aad(prefix:address:)` |
| **`optString` 双实现（跨文件）** | 见 2.1 —— SwiftDid 与 SwiftNft 各一份 | 同 2.1 |

> 注：2.2 中的前 3 项集中在 SwiftDid 内部，是「门面 + 工具分层」未彻底时的典型残留；`DidDocumentEditor` 已抽纯函数（做得对），但调用侧仍各自内联了同款变换。

## 三、Sendable / 并发审计（跨模块汇总）

**公开 Error 枚举缺 `Sendable`（4 个 + 2 个 internal）** —— 前瞻性 P2：
`DAppConnectError`（`Models.swift:16`）、`SwiftDidError`（`DidModels.swift:204`）、`VaultError`（`VaultModels.swift:32`）、`SwiftWalletError`（`SwiftWallet.swift:239`）；internal：`ChecksumError`、`CredentialDataError`。对比：`AccountOperationError`/`AccountStoreError`/`WebviewBridgeError` 已带 `Sendable`——建议补齐统一。

**`@unchecked Sendable` / `nonisolated(unsafe)` 15 处审计：**

| 类型 | 判定 |
|---|---|
| `GRDBAccountStore` / `GRDBDidStore` / `GRDBNftStore` | ✅ 合理（GRDB `DatabasePool` 线程安全）；但缺一行「为什么安全」注释 |
| `NoRedirectDelegate`（`NftHttpClient.swift:113`） | ✅ 无状态，合理 |
| `BridgeDidResolver`（`DidResolver.swift:11`） | ⚠️ 仅因持有 `@MainActor EngineBridge`；改 `@MainActor` 可去掉 `@unchecked` |
| `ContinuationBox` / `ReadyWaitBox`（`ContinuationBox.swift:6,23`） | ❌ **真实竞态**（`onCancel` 不在主线程）→ 已列 P0-2 |
| `TinkVaultCipher`（`TinkVaultCipher.swift:6`） | ⚠️ 可变 `cachedHandle` 挂 `@unchecked`，需确认 `registerAead` 幂等/线程安全 |
| `SsrfGuard.enabled`（`SsrfGuard.swift:17`） | ⚠️ `nonisolated(unsafe) static var` 可变全局（仅 DEBUG 测试用） |

## 四、架构层观察

1. **错误吞掉是全库系统性模式**，非单点：SwiftDid 写 API→`Bool`、SwiftNft `fetchMetadataFields`→`.empty`、SwiftWallet `buildSwtcNftTransfer`→`[:]`、SwiftAccount `persistVault`→`try?`（✅ 已修复，见 P0-5）、Vault 导入重复→静默 continue。建议定一条统一策略（公开 API 一律 `throws` 或带 `Result`，内部再决定是否降级），否则错误可观测性会持续恶化。
2. **地址规范化策略不统一**：`VaultRepository.normalizedAddress`（`lowercased()`）、GRDB `LOWER(address)`（函数使索引失效）、`EthMiddleware` `caseInsensitiveCompare`、`WebOrigin.normalize`（小写+去默认端口）——同一「地址相等」语义有 4 种实现，EIP-55 checksum 大小写规则要求混合大小写地址需区分校验，建议收敛为「存储层统一小写 + 比较层 `caseInsensitiveCompare` 或规范化后比较」。
3. **桥抽象半途而废**：`EngineBridge`（`@MainActor` 协议）被 SwiftWallet/SwiftDid/WebviewBridge 三方共享，但 `SwiftDid.start()` 只对具体类型 `WebviewBridgeEngine` 调 `start()`（`SwiftDid.swift:66-68`），协议没有 `start` 需求——要么协议补 `start`，要么移除对具体类型的依赖。
4. **模块名=类名冲突**：`SwiftNft` 模块名与门面类 `SwiftNft.SwiftNft` 同名（`SwiftDid.swift:12-13` 注释已自认）——`import SwiftNft` 后类型位置会解析到类，`SwiftNft.Nft` 限定拼写不可用。属命名债务，建议门面类改名（如 `NftClient`）。

## 五、第二轮结论

- 第一轮 P0 六项**全部维持**（P0-1 Vault 访问控制已在第二轮复验；**P0-2 / P0-3 Bridge、P0-4 Nft 溢出、P0-5 Account 吞错、P0-6 Did 过期 fail-open 已修复**，见修复记录）。
- 第一轮有两处**事实性错误已被纠正**（`try append`、`VaultKeyDeriver` Sendable）。
- 新增最关键的正面结论：**代码库在 Swift 6 严格并发下零编译告警零错误**——并发/Sendable 纪律的编译器级验证通过。
- 新增一批跨模块去重与架构一致性建议（表二~四），这些是单模块审查无法发现的。
