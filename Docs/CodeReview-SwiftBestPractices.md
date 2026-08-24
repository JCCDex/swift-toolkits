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

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | **SWTC 流程污染共享 ETH 链状态**：`handleSwtcRequestAccounts` 里 `ethMiddleware.setCurrentChain(.swtc)`，之后所有 ETH DApp 拿到 `eth_chainId = 0x1`，且 `eth_sendTransaction` 无显式 chainId 时直接报 "Chain swtc does not have an EVM chainId" | `WebAppInterface.swift:329-331`（配合 `EthMiddleware.swift:127-130,175-177`） | 未做（待办） |
| 2 | **`eth_accounts` 与 `eth_requestAccounts` 混同**：都走 `requestAccounts` 弹授权框；EIP-1193 规定 `eth_accounts` 静默返回已授权账户，DApp 加载时探测会误弹窗 | `WebAppInterface.swift:233-234` | 未做（待办） |
| 3 | **gas 估算失败静默回落 21000**：`estimateGas` 抛错（revert/余额不足/节点错误）时直接签 0x5208，合约调用会被签出并广播，白白烧 gas | `EthMiddleware.swift:158-166` | 未做（待办） |
| 4 | **`sendTransactionWithPassword` 丢弃密码**：参数 `password _: String` 被忽略，直接走可能命中 5s/20s 缓存的 `CachingSecretProvider`，API 承诺的认证强度与实现不符 | `SwtcMiddleware.swift:88-90` | 未做（待办） |
| 5 | **整条 RPC 管线绑死 MainActor**：`WebAppInterface`/`EthMiddleware`/`SwtcMiddleware`/`NodeProvider`/`NftProvider`/`WalletSigning` 全部 `@MainActor`，RPC 网络 I/O、签名、DID/IPFS 加密都在主线程，节点慢即卡 UI（`Interfaces.swift:20` 注释自认是「标 @MainActor 以通过 Swift 6 严格并发」） | 多个文件 | ✅ `NodeProvider`/`NftProvider` 协议已去 `@MainActor`（网络 I/O 移到协作线程池；MainActor 中间件 await 时不阻塞主线程）——非 Sendable 参数（`[String: Any]`/`[Any]?`）经 `JsonObjectParams`/`JsonArrayParams`（@unchecked Sendable 包装）跨隔离传递；`estimateGas`/`getEvmNfts` 签名同步，测试 Fake/demo 实现更新。中间件/签名/DID 桥保持 @MainActor（WKWebView 必须主线程，宿主接线面） |
| 6 | **`DAppConnectError` 非 `Sendable`** 却跨 actor 边界（`CachingSecretProvider` actor 内 `Task<String?, Error>`） | `model/Models.swift:16` | ✅ 已补 `Sendable`（随 Sendable 批） |
| 7 | **`load*` 前缀误用**：`loadInitJs`/`loadAddressJs`/`loadUpdateChainIdJs`/`loadEip6963IconOverrideJs` 实际是生成 JS 字符串（只有 `loadProviderJs` 真读资源）；且 `WebAppInterface` 三个同名实例方法是 `DAppConnectSdk` 静态方法的透传，双入口 | `DAppConnectSdk.swift:80-132`、`WebAppInterface.swift:49-61` | 未做（待办） |
| 8 | **`route()` 约 120 行**：分发 + 参数提取 + 错误策略混在一个 switch；且 `handleEthSignTypedData` 收整个 request、其余 handler 收提取后的参数，风格不一 | `WebAppInterface.swift:202-323` | 未做（用户评估后回滚：原实现参数提取在 handler 内一次完成，route 分发行更短，改动反而啰嗦） |
| 9 | **每条消息在主线程 JSON 解析**（含大 NFT/DID payload） | `WebAppInterface.swift:105-109` | ✅ 已随 E-1 修复：消息 JSON 解析移入 `Task.detached`（先提取值类型，`ParsedMessage` 包装不可变结果），主线程只做授权/路由/回传 |
| 10 | **`getChainId()` 与 `getCurrentChainIdHex()` 逐字节相同**，删一个 | `EthMiddleware.swift:63-66` vs `241-244` | ✅ 已删 `getCurrentChainIdHex()`（与 `getChainId()` 逐字节相同），无调用点残留 |
| 11 | `CachingSecretProvider`：`clearCache()` 后 in-flight 完成仍会回填缓存（锁屏后明文最多再服务 20s）；in-flight task 取消时未真正取消委托任务 | `CachingSecretProvider.swift:87-89,43-47` | 未做（待办） |
| 12 | `isSafeUrl` 正则弱：拒绝单标签 host（localhost）、接受非法端口、拒绝 IPv6、端口区间未锚定 → 改用 `URLComponents` 结构化校验 | `DAppConnectSdk.swift:137-140` | 未做（待办） |
| 13 | `failure(_:_:)` 对非 `DAppConnectError` 直接透传 `localizedDescription` 给页面（可能泄漏内部路径）；缺参错误用 -1 而非 EIP-1193 的 -32602 | `WebAppInterface.swift:615-624` | 未做（待办） |
| 14 | 死代码：`ChainConfigProvider` 定义但从未使用；`WebAppInterface.chainProvider` 只写不读；`DAppConnectError.missingParameters` 从未抛 | `Interfaces.swift:42-44`、`WebAppInterface.swift:18,79-84` | 未做（待办） |

### SwiftVault

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | `changePassword` 重建 `newStore` 时**丢弃 biometric**（旧 store 的 biometric 未迁移） | `VaultRepository.swift:274-287` | 未做（待办） |
| 2 | **KDF 三重复制**：`verifyPassword`/`unlock`/`ensureUnlocked` 各自写一遍「derive + 常量时间比对」，派生的 key 被丢弃后 `unlock` 再派生一次 → 提取一个私有 `deriveAndVerifyKey` 助手 | `VaultRepository.swift:71-111,393-404` | ✅ 已随性能专项 B-3 收敛为私有 `deriveAndVerifyKey`（单点实现） |
| 3 | 同步 Argon2（64–256 MiB 内存）在 actor 上执行，且 README 写的是 `try await`；应挪到后台或提供 async 变体 | `Argon2idVaultKeyDeriver.swift` | 未做（待办） |
| 4 | 导入路径 2–4 次全量 store load/save 往返（`importMnemonic`/`importSecret` 内部先调 `importPrivateKey` 再自己 load+append+save） | `VaultRepository.swift:128-168` | ✅ 已随存储专项 C-6 改单次 load + save（1 load + 1 save，对齐 `importPrivateKeys` 批量范式） |
| 5 | `importPrivateKeys` 重复导入静默 continue；`clearAllData(password: nil)` 无密码即清库（API 设计陷阱，调用方误传 nil 即免密清库） | `VaultRepository.swift:170-189,325-331` | 未做（待办） |
| 6 | `Wipe.swift` 全库无引用（生产死代码），`sessionKey` 从不主动擦除 | `util/Wipe.swift`、`VaultRepository.swift:13` | 未做（待办；Data COW 陷阱见补充细节） |

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

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | `importSubAccount` 以 `Keypair(privateKey: "", ...)` 走 `importSingleAccount` → `persistVault` 会 `importPrivateKey(address, Data())` 加密**空私钥**（当前仅因 `VaultRepository.importPrivateKey` 判重短路才没出事）→ 加 `persistKey: Bool` 参数 | `AccountManager.swift:144-164,289` | 未做（待办） |
| 2 | **`removeAccount` 同名陷阱**：`SwiftAccount.removeAccount(accountId:)` 是裸 store 删除（不验密、不清理 vault），`AccountManager.removeAccount(accountId:password:)` 才是编排删除——同名异构行为，走门面会静默遗留 vault 密钥 | `SwiftAccount.swift:67-69` vs `AccountManager.swift:232-250` | 未做（待办） |
| 3 | `removeAccount` 双重 Argon2：先 `verifyPassword` 再 `removeAddress` → `ensureUnlocked` → `unlock` 再派生一次 | `AccountManager.swift:237,246` | ✅ 已随性能专项 B-3 改 `unlock` + `removeAddressUnlocked`（单次派生） |
| 4 | `SwiftAccount` 是 `AccountStore` 的 ~26 个方法纯透传（零逻辑），会随协议漂移 → 直接暴露 `store` 或让门面 conform `AccountStore` | `SwiftAccount.swift:29-131` | 未做（待办） |
| 5 | `deriveSubAccount` 连续两次相同 `findById`（第一次 guard 是死代码） | `AccountManager.swift:177-182` | 未做（待办） |
| 6 | `(try? findNonRootAccount(...)) != nil` 占用探测：store 出错按「未占用」处理，反而继续派生该 index | `AccountManager.swift:201` | 未做（待办） |
| 7 | 无 `(address, chain)` 唯一索引：预检 + 插入非原子，并发导入同地址会重复入库 | `GRDBAccountStore.swift:23-34` | 未做（待办） |
| 8 | 观察流出错时静默 `finish()`，消费方无法感知流死亡 | `GRDBAccountStore.swift:283-284` | 未做（待办） |
| 9 | UPDATE 方法不检查影响行数（更新不存在的 id 静默成功，Kotlin Room `@Update` 有行数返回） | `GRDBAccountStore.swift:142-173` | 未做（待办） |

### SwiftNft

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | **SSRF 守卫不覆盖返回给宿主的 URL**：恶意元数据 `image: "http://192.168.1.1/..."` 会被模块原样交给宿主加载器，宿主若不复检即被 SSRF | `SwiftNft.swift:358-408` | ✅ `resolveRemoteImageUrl` 非 `data:` 返回全部过 `SsrfGuard.check`（`isReturnable`） |
| 2 | 注入自定义 `URLSession` 时 GET 会**静默跟随重定向**（no-redirect 策略只在默认 client 生效） | `NftHttpClient.swift:39-45` | ⚠️ 部分：**无 request 级开关**（`httpShouldFollowRedirects` 是 `URLSessionConfiguration` 属性，review 建议不可行）——默认 client 靠 `RedirectPolicyDelegate` 按方法区分（POST/RPC 跟随、GET 拒绝）；注入 session 无法库内强制，已强化文档指引（配置 `httpShouldFollowRedirects = false`） |
| 3 | `removeAll()` 后完成的 fetch 会回填缓存（generation counter 修复） | `AsyncMemoCache.swift`（原 `NftMetadataImageCache.swift:36-49,60-67`） | ✅ 已加 `generation` 计数 + 回归测试 |
| 4 | **`LOWER(ownerAddress)` 使 `swtc_nfts.ownerAddress` 索引失效**（全表扫描）+ 大小写混合写入；`issuer` 无索引 | `GRDBNftStore.swift:147-153,176` | ✅ v2 迁移：旧行 LOWER 归一 + `idx_swtc_nfts_issuer`；写入归一（ownerAddress/issuer）、查询去 `LOWER()` |
| 5 | `deleteSwtcNftsByOwner` 循环内逐条查询 → N+1 | `GRDBNftStore.swift:213-218` | ✅ 元组 `IN (...)` 一次性批量查 `nft_meta` |
| 6 | `SELECT *` 拉取可数 MB 的 `fullContent` 列 | `GRDBNftStore.swift` | ✅ `getNftMeta`/批量查询投影所需列（fullContent 为 Optional，缺失列解码为 nil） |
| 7 | `eth_call` 无记忆化：同一 tokenURI 反复 `fetchRpc` | `EthTokenUriResolver.swift` | ✅ 已随性能专项 D-1 完成：`SwiftCore.AsyncMemoCache` 记忆化（按 `(chainId, contract, tokenId)` 成功才缓存 + in-flight 去重 + LRU 上限）+ 3 个回归测试 |
| 8 | SSRF 残余缺口：NAT64 `64:ff9b::/96`、Teredo `2001::/32`、`2001:db8::/32` 文档段未拦截；DNS rebinding TOCTOU 已在注释中承认 | `SsrfGuard.swift:132-162` | ✅ 已拦 `64:ff9b::/96`、`2001:db8::/32`、IPv4 `192.88/16`（6to4 relay）；Teredo（压缩形式难判）与 DNS TOCTOU 保留注释说明 |
| 9 | `String` 用 `index(_:offsetBy:)` 做随机访问下标（`EthTokenUriResolver.swift:128-134`），O(n²) 且 `offsetBy: range.count` 在超界时可能越界 | `EthTokenUriResolver.swift` | ✅ 改 `dropFirst + prefix`（越界安全） |

**SwiftNft 补充细节（第二轮审查新增，均验证；✅ = 已修复）：**

- ✅ **SSRF 守卫补充缺口**：已拦 `64:ff9b::/96`、`2001:db8::/32`、IPv4 `192.88/16`（6to4 relay）+ 回归测试（对照公网 `2001:4860` 不受影响）；IPv4-translated hex 形态与 Teredo 保留待办（压缩形式判定成本高）
- ✅ `canonicalizeHttpIpfsUrl` 路径穿越：已剥 `..` 段（IPFS 路径不含 `..`，剥除安全）+ 回归测试 | `NftUrlUtils.swift:106-115`
- `data:image/svg+xml` 放行：注释已警告 SVG 可含脚本——宿主必须用 `UIImage/CGImage` 渲染、禁止 `WKWebView`（建议在 API 文档显式声明） | `NftUrlUtils.swift:37-40`
- ✅ **`SwtcTokenUriResolver.gateway`** 已改 `let`（init 缺 http(s) scheme 校验的缺口保留：门面 `SwiftNft.init` 已兜底回退，见下条）
- ✅ 死代码：`SwiftNft.swift` 非法网关告警已改为与原始 `config.ipfsGateway` 比较，回退时正确触发
- ✅ `fetchMetadataFields` 已补 `logFailure`（guard / 空体 / 传输错误三路）
- ✅ `resolveEthrAvatar` 入口守卫校验：`guard !tokenId.isEmpty, !contract.isEmpty, let chainId else { return nil }`（chainId 无默认值，未知 chainId 直接 nil，不再查 `"0x0"`；eth_call 由宿主 `getRpcNode` 决定）；issuer 大小写已随 P1#4 写入归一，`nft_meta` 落空风险消除
- ✅ `buildCredentialAssetKey`：`normalized!` 改 `nilIfBlank ??`，死尾显式 `"image:"`
- ✅ `ValueObservation` 观察流：手动值去重（等价 distinctUntilChanged）+ `.bufferingNewest(1)` 有界缓冲 + 出错记日志 | `GRDBNftStore.swift:409-427`
- ✅ `isDataImageUrl` 已显式文档警告 `data:image/svg+xml` 可含脚本（宿主须 `UIImage`/`CGImage` 渲染、禁 WKWebView）
- ✅ **默认 client 已改单 `URLSession`**：重定向策略由 `RedirectPolicyDelegate` 按请求方法区分（POST/RPC 跟随、GET 拒绝），原 GET/RPC 双 session 删除；`fetchRpc` 不再做 SsrfGuard 建连检查（RPC 节点属宿主注入信任面，SsrfGuard 亦不覆盖重定向目标——由宿主保证节点可信，避免误拦本地/私有链节点），GET 元数据拉取仍全量过 SsrfGuard | `NftHttpClient.swift`
- 未做（保留待办）：`getaddrinfo` 阻塞 + 每次 GET fetch 双次 SSRF 检查（facade 缓存门 + client 建连门，属纵深防御，开销可接受）| `SsrfGuard.swift:38-58`、`NftHttpClient.swift`
- ✅ **命名批（SwiftNft 部分已落地，见修复记录）**：`Url`→`URL` 全部改完（`NftUrlUtils` 8 个 + 门面 `SwiftNft` 3 个 + SwiftDid 门面透传 + 测试同步）；`get*` 前缀清除（`NftStore` 协议 6 处：`getNftMeta`→`nftMeta`、`getSwtcNftByIssuerAndTokenId`→`swtcNftByIssuerAndTokenId`、`getSwtcNftByTokenId`→`swtcNftByTokenId`、`getEvmNftItemByContractAndTokenId`→`evmNftItemByContractAndTokenId`、`getEvmNftItem`→`evmNftItem`、`getNftCollectionsFlow`→`observeNftCollections`）；hex→UTF-8 字符串处理归口 SwiftCore（`String.trimmingPrefix/removingPrefix/hex2utf8`，删 NftUrlUtils 本地私有扩展）；`optString` 已删除（调用点统一走 `readString(_:default:)`，`optDict`/`optArray` → `readDict`/`readArray`，org.json 风格命名清除） | `NftUrlUtils.swift`、`NftStore.swift:14-40`

### SwiftDid

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | 8 个公开写 API 全部 `catch { return false / DidWriteResult(success: false) }`：校验失败与传输失败不可区分、零日志，联调只能靠猜 | `SwiftDid.swift:262-509` | ✅ 已加 `os.Logger`：`logWriteError(_:error:did:)` —— `.public` 隐私（Release 可见）+ 安全错误摘要（NSError 只打 `domain#code` 防 payload 泄漏，纯枚举打 case 名）+ `did` 上下文 |
| 2 | `start()` 只对具体类型 `WebviewBridgeEngine` 调 `engine.start()`，`destroy()` 走协议 `bridge.destroy()` —— 类型判断破坏抽象 | `SwiftDid.swift:64-79` | ✅ 已修复（见四 #3 / commit 8f9ab98） |
| 3 | `buildGenerateVcParams` 校验失败返回空字典 `[:]`，空参继续调桥接 `generateVC`（静默失败、错误信息全丢）→ 应抛错 | `SwiftDid.swift:819-835` | ✅ 已改 `throws`，错误向上抛（调用方 catch 记日志） |
| 4 | `SwiftDidError` 部分 case 从未抛出（死代码）；门面 866 行，建议拆分 | `SwiftDid.swift` | ✅ 死代码 case（`notInitialized`/`didNotFound`）已删；门面拆分未做（独立重构项） |
| 5 | `formatUtc`/`parseISO8601` 每次新建 `ISO8601DateFormatter`（创建开销大）；建议 `Date.ISO8601FormatStyle`（Sendable、免分配） | `DidJson.swift:89-124` | ✅ 已改 `Date.ISO8601FormatStyle`（含小数/无小数双策略解析，删 ISO8601DateFormatter 扩展） |

**SwiftDid 补充细节（第二轮审查新增，均验证；✅ = 已修复）：**

- ✅ 全库唯一强制解包：`DidCoreService.swift:89` `chainUpdated > localUpdated!` 已改 `localUpdated.map { chainUpdated > $0 } ?? true`
- ✅ GRDB 缺索引：`observeAll` 的 `ORDER BY updatedAt DESC` 与 `deleteExpiredPending` 的 `updatedAt < ?` 已加 v2 迁移索引（`idx_did_documents_updatedAt` / `idx_did_pending_updatedAt`）
- ✅ 死代码：`SwiftDidError.notInitialized` / `didNotFound` 已删；`DidJson.isBlank` 已删（去重批）
- ✅ 重复实现：`credentials(from:)` vs `readCredentials`、`previousCid` 变换 ×3（去重批）
- ✅ `loadPending` 主键 `(kind, did)` 唯一但返回 `[DidPending]` → 协议/实现/调用点改为 `DidPending?`（测试断言同步）
- ✅ 访问控制：`Keccak256`/`ChecksumUtils`/`BridgeDidResolver`/`DidCoreService` 已收紧为 `internal`（演示未使用、测试 @testable）；`GRDBDidStore` 的 `@unchecked Sendable` 保留（DatabasePool 本身 Sendable，final+只读本可隐式；保留以兼容 GRDB 版本差异，已注释）
- ✅ 其他：`queryAndValidateVcid` 桥接错误已记日志（不再与"无效 VC"混淆）；`generateProfileVC` 用 `credentials(in:)` 双键别名；`isSelf` 处理多 controller 空格分隔；`updateDidAvatar` 改 `upsertCredential` 原位替换（不再 filter+append 打乱顺序）

### SwiftWallet

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | `buildSwtcNftTransfer` 解析失败返回 `[:]` 吞错：下游 `SwtcMiddleware` 只注入 Sequence 就签名 → 应 throw 带描述的错误 | `SwiftWallet+WalletSigning.swift:42-51` | ✅ 已改 `throw SwiftWalletError.invalidResponse`（带 120 字符截断预览；不落原始 payload）+ 回归测试 |
| 2 | `WalletModels.swift:56` `accounts: [SubWallet] = []` 默认值对合成 `Decodable` 无效，JS 缺 `accounts` 键直接 `keyNotFound` → 自定义 `init(from:)` + `decodeIfPresent ?? []` | `WalletModels.swift:56` | ✅ `GenerateHDWalletResult` 自定义 `init(from:)`（`decodeIfPresent ?? []`）+ 2 个回归测试（缺键/有键） |
| 3 | `SwiftWalletError` 缺 `Sendable`；`buildSwtcNftTransfer` 与类内同名方法仅返回类型不同（易混淆） | `SwiftWallet.swift:239` | ✅ Sendable 已补（随 Sendable 批）；同名方法已消除——类自身方法改 `buildSwtcNftTransferRaw`（返回 String），协议实现独占 `buildSwtcNftTransfer`（返回 `[String: Any]`） |

### SwiftWebviewBridge（P1 部分）

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | in-flight `evaluateJavaScript` Task 无追踪、不随超时/`destroy()` 取消：JS 卡死则任务强持 client+runtime 直到进程结束 | `WebviewBridgeClient.swift:109-116` | ✅ `PromiseGateway` 新增 `attachJsTask`，`PendingCall.jsTask` 随 `remove`/`clearAll`/`finish` 取消（`callJsMethod` 创建 JS 任务后补挂）+ 回归测试 |
| 2 | `resetReady()` 静默丢弃 ready-waiters → 等待方挂到超时 | `PromiseGateway.swift:102-105` | ✅ `readyListeners` 改 `(Error?) -> Void`：`onBridgeReady` 传 nil（成功）、`resetReady` 传 `.webViewUnavailable`（立即失败恢复，不再挂超时）+ 回归测试 |
| 3 | `UInt64(timeoutMs * 1_000_000)`：负值/NaN/Infinity → 运行时 trap；亚毫秒截断 | `PromiseGateway.swift:42,75` | ✅ 新增 `sleepNanoseconds`：非有限/≤0 clamp 为 0（不 trap），亚毫秒向上取整为 1ms（避免截断成 0 立即超时）；两处超时共用 + 回归测试 |
| 4 | `WebviewBridgeConfig.resourceBundle` 死配置（实际只用 `bundle:` 参数） | `WebviewBridgeConfig.swift:13,20` | ✅ 已删 `resourceBundle` 属性/init 参数与 `bridge(named:in:)` 的 `bundle` 参数（client 的 `init(bundle:)` 是唯一入口） |
| 5 | `parseResult` 中 `guard object["result"] != nil` 之后的 `guard let result = object["result"]` 是不可达代码（`{result: null}` 产出 NSNull 非 nil） | `PromiseGateway.swift:145-147` | ✅ 合并为单个 `guard let result = object["result"]`（NSNull 也能解出 → 序列化 "null"，语义不变），删不可达分支 |

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

3. ✅ **已实现**：`ISO8601DateFormatter` 每次新建（`DidJson.swift:102-124`、`SwiftDid.formatUtc`）——
   已改 `Date.ISO8601FormatStyle`（Sendable、零分配，iOS 15 起可用）；日期处理全量归口
   `SwiftCore/Date.swift`（`Date.nowISO`/`parseISO8601`/`nowMillis`/`formatUtc`），
   `DidJson`/`SwiftDid.formatUtc`/`DidCoreService.nowMillis` 及各模块内联
   `Date().timeIntervalSince1970 * 1000`（SwiftNft ×3、SwiftDappConnect ×1）统一收敛
   （见修复记录「日期批」）。

4. **已核实「非热点」，无需优化**（避免过度工程）：`Path.derivationPath` 插值（每次导入/派生仅 1 次，非循环内）；`boolFromRaw`（trim+lowercase，每 RPC 一次）；`ChainType.fromBip44Code` 线性扫描（N=7，static dict 仅在枚举膨胀时值得）。

### B. 加密 / 哈希

1. ✅ **已实现**：Keccak absorb 逐字节组装 UInt64 lane（`Keccak256.swift:47-51`）——改为
   `withUnsafeBytes` + `loadUnaligned` 按 8 字节 lane 读入（每块 17 次 lane 异或取代 136 次
   div/mod + 移位），KAT 10/10（含长消息多块向量）验证哈希一致。
2. ✅ **已实现**：`permute` 每次调用重新分配 `c/d/b` 三个 25 元素数组——工作区提升到
   `hash()` 一次性分配、多块/多次 permute 复用（`permute(&state, c:&c, d:&d, b:&b)`，
   KAT 10/10 回归验证哈希一致）。
3. ✅ **已实现**：Argon2 重复派生——`VaultRepository.verifyPassword`/`unlock`/`ensureUnlocked`
   三处重复的「派生 + proof 校验」收敛为私有 `deriveAndVerifyKey` 助手（单点实现，未设密码
   → nil、密码错 → nil、正确 → 派生 key）；`AccountManager.removeAccount` 由
   `verifyPassword` + `removeAddress`（两次完整 64 MiB KDF）改为 `unlock` +
   `removeAddressUnlocked`（单次派生，已解锁路径不再二次 KDF；`removeAddressUnlocked` 为
   新增公开 API，调用方须已解锁——注释已声明）。
4. ✅ **已实现**：随机数生成——`VaultRepository.randomData` 改 `SecRandomCopyBytes`
   （密码学安全源 + 批量生成，替代逐字节 `UInt8.random`，`VaultRepository.swift:426-432`）。

### C. 存储 / GRDB

1. ✅ **已实现**：`LOWER()` 使列索引失效（全表扫描）——Account 表（`GRDBAccountStore` 6 处
   `LOWER(address)`）与 SwiftNft EVM 两表（`evm_nft_items`/`evm_nft_collections` 的
   `LOWER(ownerAddress)`/`LOWER(contractAddress)`）已全量收敛：v2/v3 迁移旧行统一小写 +
   写入归一（`AccountRecord`/upsert/insert 用 `normalizedAddress`/`lowercased()`）+ 查询去
   `LOWER()`，列索引生效（swtc 表已随 P1#4 完成）。
2. ✅ **已实现**：`SELECT *` 拖回多 MB `fullContent`（`GRDBNftStore.swift:122-127` 等头像查询）→ 投影所需列（contract/tokenId/name/image/tokenUri/updatedAt）。
3. ✅ **已实现**：N+1：`deleteSwtcNftsByOwner`（`GRDBNftStore.swift:213-218`）逐行查 `nft_meta` → 每 owner 一次批量查询 + 内存字典。
4. ✅ **已实现**：缺索引——`swtc_nfts.issuer`（v2）、`did_documents(updatedAt)` / `did_pending(updatedAt)`（SwiftDid v2）已补；Account/EVM 表列索引随 C-1 去 `LOWER()` 后生效。
5. ✅ **已实现**：ValueObservation 每次写都重发射（无 `distinctUntilChanged`，`GRDBNftStore.swift:392-406`）+ `AsyncStream` 默认无界缓冲 → 手动值去重（等价 `.removeDuplicates()`）+ `.bufferingNewest(1)`。
6. ✅ **已实现**：Vault 全量 load/save 往返——`importPrivateKey` = 2 load + 1 save → 1 load + 1 save；`importMnemonic`/`importSecret` = 4 load + 2 save → 1 load + 1 save（单次 load 判重 + 追加 + 单次 save，对齐 `importPrivateKeys` 批量范式）。
7. `observeCurrentAccount` 每 tick 2 查询（`GRDBAccountStore.swift:54-57`）——单读事务一致快照，非 N+1，可接受（记录在案）。

### D. 网络

1. ✅ **已实现**：`eth_call` 无记忆化——`EthTokenUriResolver` 复用 `SwiftCore.AsyncMemoCache`
   （原 `NftMetadataImageCache` 并入 SwiftCore 通用化：按 key 只缓存成功结果 + per-key
   in-flight 去重 + LRU 上限 + generation 防旧回写；图片缓存与 eth_call 缓存共用同一实现，
   `TokenUriCache` 重复实现已删）；`resolveEthrAvatar` 缺 tokenUri 的重复调用第二次起
   本地命中，不再发 `fetchRpc`。+3 回归测试（并发去重 / 失败不缓存 / 注入 gateway）。
2. ✅ **已实现**：双 IPFS 归一化——`EthTokenUriResolver.normalizeTokenMetadataUri` 加
   `gateway` 参数（init 注入 `gateway`，内部归一单点化）；门面 `resolveEthrTokenUri`
   保留按配置 gateway 的兜底归一（resolver 若漏过 ipfs:// 或 http `/ipfs/` 路径强制换
   配置网关；宿主注入 resolver 时建议 gateway 与 `SwiftNftConfig.ipfsGateway` 一致）。
3. ✅ **已实现**：VC 逐字段重复 JSON 解析——`SwiftNft` 三处调用点（`resolveSwtcAvatar`/`resolveEthrAvatar`/`ensureSwtcCredentialMetadata`）改为 `parseVc` 解析一次 + `Json.readString(root, ..., default:)` 取字段（原每字段重新 `JSONSerialization`，`SwiftNft.swift:100-104` 调 4 次、`:146-149` 调 3 次）。
4. ✅ **已实现（部分）**：`getaddrinfo` 阻塞系统调用在协作线程池（`SsrfGuard.swift:38-58`）——
   `fetchRpc` 已移除 SsrfGuard 建连检查（RPC 属宿主注入信任面）；GET 拉取的 SsrfGuard
   DNS 解析阻塞保留（并发增长时再评估移出线程池）；「facade 缓存门 + client 建连门」
   双次检查属纵深防御、开销可接受（记录在案）。
5. ✅ **已实现**：默认 client 持有两个 `URLSession` 实例——已合并为单 session +
   `RedirectPolicyDelegate` 按请求方法区分策略（POST/RPC 跟随、GET 拒绝），见 SwiftNft
   补充细节/命名批。
6. ✅ **已实现**：`loadProviderJs` 每次调用重读 bundle 资源 + 全文件 `replacingOccurrences`
   （`DAppConnectSdk.swift:82-83`）→ 模板改 `static let` 缓存，仅替换 token。

### E. 主线程 / 每调用开销

1. ✅ **已实现**：DAppConnect 每条消息主线程 `JSONSerialization`（`WebAppInterface.swift:105-109`，
   含大 NFT/DID payload）——解析移到 `Task.detached`（先提取值类型：body 文本 /
   `frameInfo` 的 isMainFrame/scheme/host/port，非 Sendable 对象不跨线程），解析完成后回
   主线程 `handleMessage` 继续授权/路由（origin 推导与回传逻辑不变）。
2. ✅ **已实现**：`JSONDecoder` 每调用新建（`WebviewBridgeClient.swift:172`）→ 类级
   `static let sharedJSONDecoder` 复用（线程安全）；`PromiseGateway` 的 Task/box 结构
   已在 P0-2/P0-3 修复中收敛（ContinuationBox + 主线程串行），`parseResult` 非字符串
   result 的二次序列化属语义必需（提取 result 子值），保持。
3. ✅ **已实现**：每条 console 消息主线程 `NSLog`（`WebviewBridgeClient.swift:304`）→
   包 `#if DEBUG`（release 零日志开销；`allowsConsoleForwarding` 开关仍在）。
4. ✅ `AsyncMemoCache`（原 `NftMetadataImageCache`，LRU 上限 + per-key in-flight 去重）**设计正确，保持**；`removeAll()` 后回填竞态已用 generation counter 修复（正确性 P1#3，已落地）。

### F. 待量化（收益需 Instruments 确认）

- ✅ **已优化**：主线程 `deliver` 的 `jsQuote` 双程全串拷贝（`WebAppInterface.swift:182-198`）——
  `DAppConnectSdk.jsQuote` 改 `JSONSerialization` fragmentsAllowed 单次序列化（JSON 字符串转义
  是 JS 字面量转义的超集，消除 4 次 `replacingOccurrences` 全串拷贝）。
- ✅ **已优化**：`swtcNftJson`/`ethNftJson` 逐条 `[String: Any]` 构建（`WebAppInterface.swift:630-671`）——
  响应结构构造不可避免，`reserveCapacity` 预分配避免 rehash。
- ✅ **已优化**：`String(describing: result)` 兜底序列化（`PromiseGateway.swift:156`）——
  兜底分支先取 `NSNumber.stringValue`（固定格式，与 locale 无关；`String(describing:)` 会随
  locale 变小数点/分组，保留为最后手段）。

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

- **日期批（2025-08-22）**：日期/时间戳处理全量归口 `SwiftCore/Date.swift`——新增
  `Date.nowMillis()`（epoch 毫秒）与 `Date.formatUtc(_:)`（Asia/Shanghai 展示格式，
  值类型 Calendar 免 DateFormatter 分配）；替换 `DidCoreService.nowMillis`、
  `SwiftDid.formatUtc`（删两处模块内实现）、SwiftNft 3 处内联
  `Int64(Date().timeIntervalSince1970 * 1000)`（GRDBNftStore/SwiftNft/NftModels ×2）、
  SwiftDappConnect `CachingSecretProvider.nowMs`；测试 `SwiftDid.formatUtc` → `Date.formatUtc`。
  性能专项 3（ISO8601DateFormatter 每次新建）✅。`NftModels`/`CachingSecretProvider` 补
  `import SwiftCore`。
- **DidJson 并入 SwiftCore 并按职责拆分（2025-08-22）**：`SwiftDid/Util/DidJson.swift` 并入
  `SwiftCore` 后按用户要求拆分，DID 文档字段读取（`readProfileField` ×2 / `extractUpdated`）
  单独成 `SwiftDid/Util/DidJson.swift`（模块内 `internal`）——`Json.swift` 保留通用 JSON
  （取值/解析/序列化 + 缺失文档哨兵 `isEmpty`，原 `isMissingDidDocument` 改名）；
  **新增 `SwiftCore/Date.swift`**（`Date.nowISO`/`nowISO(offsetMillis:)`/`parseISO8601`，
  日期从 Json 移出，`extension Date`）。
  相似 API 以 `Json` 为准：`optString` **删除**（调用点统一 `readString(_:_:default:)`）、
  `optDict`/`optArray` → `readDict`/`readArray`（org.json 风格命名清除）；
  SwiftDid 5 个文件（门面/DidCoreService/DidDocumentEditor/DidCredentialHelper + 测试）
  调用点全量改 `Json.*`/`DidJson.*`/`Date.*`，`DidCoreService`/`DidDocumentEditor` 补
  `import SwiftCore`；模块 README 文件树同步。
  `fetchRpc` 删除 ssrfAllowed 建连检查（RPC 节点属宿主注入信任面、SsrfGuard 不覆盖重定向
  目标，宿主保证节点可信；GET 拉取仍过 SsrfGuard），协议注释/设计文档/README 同步。
- **SwiftNft 命名批 + 补充批 3（2025-08-22）**：`Url`→`URL` 全量改名（NftUrlUtils 8 个工具 +
  SwiftNft 门面 3 个 + SwiftDid 门面透传 3 个 + 测试同步）；`NftStore` 协议 `get*` 前缀清除 6 处
  （`getNftMeta`→`nftMeta` 等，`getNftCollectionsFlow`→`observeNftCollections`）；
  字符串处理归口 SwiftCore——新增 `String+Manipulation.swift`
  （`StringProtocol.trimmingPrefix/removingPrefix` + `String.hex2utf8`，删 NftUrlUtils
  本地私有扩展，按用户要求「string 处理直接移入 swiftcore」）；
  `resolveEthrAvatar` 改入口守卫 `guard !tokenId.isEmpty, !contract.isEmpty, let chainId else { return nil }`
  （chainId 无默认值，未知 chainId 直接 nil，`Json.readLong` 不带 `default: 0`，按用户 159 行方案）；
  `NftHttpClient` 单 `URLSession` + `RedirectPolicyDelegate`（POST/RPC 跟随、GET 拦截）。
  三套件 256 用例通过。`getaddrinfo`/双次 SSRF 检查/`optString` org.json 风格保留待办。
- **SwiftNft 补充批 2（2025-08-22）**：`resolveEthrAvatar` 未知 chainId（==0）跳过 `"0x0"` 查库；
  GRDBNftStore 观察流加值去重 + `.bufferingNewest(1)` + 出错日志；`isDataImageUrl` SVG 渲染警告。
  `getaddrinfo`/双 session/命名批保留待办（见补充细节）。SwiftNftTests 132/132 通过。
- **SwiftNft P1 批（2025-08-22）**：返回宿主 URL 过 SSRF（P1#1）；缓存 `removeAll` 期间回填用
  generation 计数拦截（P1#3）；swtc_nfts 写入归一 + v2 迁移 `issuer` 索引 + 查询去 LOWER（P1#4）；
  `deleteSwtcNftsByOwner` 批量查 nft_meta（P1#5）；`getNftMeta`/批量查询投影去 fullContent（P1#6）；
  SSRF 补 NAT64/6to4/文档段（P1#8）；安全下标（P1#9）。补充细节：网关告警死代码修复、
  `fetchMetadataFields` 日志、`buildCredentialAssetKey` 去 `!`、`canonicalizeHttpIpfsUrl` 剥 `..`、
  `SwtcTokenUriResolver.gateway` 改 `let`。P1#2 部分（注入 session 禁重定向无 request 级 API，
  文档强化）。+3 回归测试，SwiftNftTests 35/35、目标 132/132 通过。
- **SwiftDid 补充批（2025-08-22）**：强制解包改 `map ?? true`；GRDB v2 迁移补
  `did_documents(updatedAt)`/`did_pending(updatedAt)` 索引；`loadPending` 协议/实现改 `DidPending?`
  （调用点与测试断言同步）；`Keccak256`/`ChecksumUtils`/`BridgeDidResolver`/`DidCoreService` 收紧
  `internal`；`queryAndValidateVcid` 错误记日志、`generateProfileVC` 双键别名、`isSelf` 多 controller、
  `updateDidAvatar` 改 `upsertCredential` 原位替换。SwiftDidTests 25/25、目标 102/102 通过。
- **SwiftDid P1 批（2025-08-22）**：8 个写 API 吞错补 `os.Logger` 日志；`buildGenerateVcParams`
  校验失败改抛错（不再 `[:]` 空参调桥）；删 `SwiftDidError.notInitialized`/`didNotFound` 死代码 case；
  `DidJson` 日期函数改 `Date.ISO8601FormatStyle`（Sendable、免分配，删 ISO8601DateFormatter 扩展）。
  SwiftDidTests 25/25、目标 102/102 通过。
- **Sendable 批（2025-08-22）**：三、Sendable 审计全部落地——6 个 Error 枚举补 `Sendable`；
  `BridgeDidResolver` 改 `@MainActor` 去掉 `@unchecked`；GRDB×3 / NoRedirectDelegate / TinkVaultCipher
  （actor 限定） / SsrfGuard.enabled（DEBUG 一次性）补「为什么安全」注释。7 模块 293 测试通过。
- **架构批（2025-08-22）**：四 #3——`SwiftDid.start()` 移除对 `WebviewBridgeEngine` 具体类型的
  特判，改为协议统一 `try self.bridge.start()`（与 SwiftWallet 一致；自定义 EngineBridge 不再
  被静默跳过），新增回归测试 `testStartInvokesBridgeStartExactlyOnce`。
- **命名批（2025-08-22）**：`SwiftNft` 门面类更名为 `NftClient`，消除「模块名=类名」对
  `SwiftNft.Nft` 等限定引用的遮蔽（架构观察 #4；测试 3 处 + 演示 1 处实例化同步更新，
  `SwiftDid.swift:9-13` 规避注释删除）。⚠️ SwiftDid 同名隐患未触发、未改（见四 #4 说明）。
- **地址/checksum 批（2025-08-22）**：SwiftCore 新增 `String.addressEquals`/`normalizedAddress`，
  SwiftVault 补 SwiftCore 依赖，`VaultRepository`/`VaultModels.matches`/`EthMiddleware` ×3 统一到
  共享实现（架构观察 #2 比较层收敛，存储层 GRDB `LOWER()` 留待 C-1）；
  `ChecksumUtils.toChecksumAddress(_:or:)` 默认值版本落地（含 `String?` 重载，nil 直接走默认值，
  消除 `map + ?? ""` 双重默认），5 个 `try?` 调用点清理（+3 个单元测试）。
- **去重批 3（2025-08-22）**：删除 SwiftDid / SwiftNft 门面的私有 `readString`/`readLong`/`readValue`
  助手，调用点直接用 `SwiftCore.Json`（SwiftNft 三处改为 `parseVc` 解析一次 + `Json.*(default:)`，
  顺带消除逐字段重复解析，性能 D-3 落地）；`Json` 增加 `readString`/`readLong` 的 `default:` 重载
  （清理 12 处 `?? ""` / `?? 0`，+1 个单元测试）。
- **去重批 2（2025-08-22）**：2.1 剩余项——SwiftCore 新增 `Json`（optString/readValue/readString/
  readLong）与 `String.isBlank`/`nilIfBlank`/`isBlank(_:)`；`DidJson.optString` 委托、
  `NftUrlUtils.optString`/`isBlank`/`nilIfBlank` 与 SwiftDid 私有扩展删除、两门面 read 助手改委托
  （5 个新单元测试）；2.2 新增项——`WalletAccount.isHDRoot` 归口中间件 HD 根过滤谓词 ×3、
  `BridgeHandlerName` 枚举归口桥通道名 ×9（1 个新单元测试）。全量 331 测试通过。
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
| ✅ **`optString` JSON 标量取值** | `DidJson.swift:25`、`NftUrlUtils.swift:170`（同签名、不同默认值语义） | 已收敛到 SwiftCore `Json.optString`（`DidJson.optString` 委托 + 删 `NftUrlUtils.optString`，5 个调用点替换） |
| ✅ **`isBlank` 空白判断** | `DidJson.swift:47`（死代码）、`DidCredentialHelper.swift:193`、`NftUrlUtils.swift:248` | 已收敛到 SwiftCore `isBlank(_:)` + `String.isBlank`（删死代码与两份私有实现） |
| ✅ **`nilIfBlank`** | `NftUrlUtils.swift:241-245`（String 扩展）、`SwiftDid.swift:862-866`（private String 扩展） | 已收敛到 SwiftCore `String.nilIfBlank`（删两份本地扩展） |
| ✅ **`firstValue()` AsyncStream 取首元素** | `SwiftDappConnect/AsyncSequence+First.swift:6`、`SwiftNft/SwiftNft.swift:508` | 已收敛到 SwiftCore `AsyncSequence.firstValue()`（删 DappConnect 重复文件 + SwiftNft 私有实现） |
| ✅ **嵌套 JSON 路径读取 `readString`/`readValue`** | `SwiftNft/SwiftNft.swift:450,475`、`SwiftDid/SwiftDid.swift:612,637`（逐字同款 `$.` 剥离 + 点分路径遍历） | 已收敛到 SwiftCore `Json.readValue/readString/readLong`；两门面私有助手均已删除（SwiftNft 调用点 parse 一次 + `Json.*(default:)`） |
| ✅ **O(n²) String `index(_:offsetBy:)` 随机访问** | `ChecksumUtils.swift:25`、`NftUrlUtils.swift:220-224`（`decodeHexToUtf8`）、`EthTokenUriResolver.swift:128-134`（subscript 扩展） | ChecksumUtils 已改 UTF-8 字节；后两处随 `Hex.decode` 移除内联循环（subscript 扩展保留待清） |
| ✅ **`jsQuote` JS 字符串转义** | `DAppConnectSdk.swift:169-176`、`WebAppInterface.swift:191-198`（逐字相同） | 已提为 `DAppConnectSdk.jsQuote`（internal），WebAppInterface 复用 |
| ✅ **地址相等语义（比较层已收敛）** | 原 4 种实现：`VaultRepository.normalizedAddress`、GRDB `LOWER(address)`、`EthMiddleware` `caseInsensitiveCompare`、`WebOrigin.normalize` | 比较层已统一到 SwiftCore `String.addressEquals`/`normalizedAddress`（Vault + DappConnect）；GRDB `LOWER()` 属存储层（见 C-1）；`WebOrigin.normalize` 为 URL origin 语义、独立保留（见「四、架构层观察 #2」） |

### 2.2 模块内跨文件重复（同模块不同文件，单文件审查易漏）

| 重复项 | 出现位置 | 建议 |
|---|---|---|
| ✅ **`previousCid` 变换 ×3** | `SwiftDid.swift:318-332`（updateDidNickname）、`:351-365`（updateDidAvatar）、`:768-782`（applyPreviousCid）——三处都在 map 闭包内重建 `IpfsStorage` service | 已抽 `DidDocumentEditor.serviceWithPreviousCid(did:service:previousCid:)`，三处复用 |
| ✅ **credentials 读取别名逻辑** | `DidDocumentEditor.credentials(from:)`（`DidDocumentEditor.swift:44-47`，注释自认镜像）vs `DidCredentialHelper.readCredentials`（`DidCredentialHelper.swift:128-131`）——同款 `credentials`/`credential` 双键回退 | 已抽 `DidCredentialHelper.credentials(in:)`，`readCredentials` 与 editor 共用 |
| ✅ **凭据查找** | `SwiftDid.findCredentialById`（`SwiftDid.swift:660-668`）vs `DidCredentialHelper.findCredentialIndex`（`DidCredentialHelper.swift:133-138`，`DidDocumentEditor.swift:70` 已在用） | 门面已复用 `findCredentialIndex` + `DidJson.stringify` |
| ✅ **AAD 前缀拼接 ×3** | `VaultRepository.addressAAD`/`mnemonicAAD`/`secretAAD`（`VaultRepository.swift:410-420`，三份 `"前缀:lowercased(address)"`） | 已收成 `aad(prefix:address:)` |
| ✅ **`optString` 双实现（跨文件）** | 见 2.1 —— SwiftDid 与 SwiftNft 各一份 | 已随 2.1 收敛到 SwiftCore `Json.optString` |
| ✅ **HD 根过滤谓词 ×3** | `EthMiddleware.swift:59,248`、`SwtcMiddleware.swift:40`（同款 `!($0.isHD && $0.parentId == nil)` 内联谓词，不查 path） | 已提为 `WalletAccount.isHDRoot`（SwiftCore，与 `isRootHD` 区分注释） |
| ✅ **桥消息通道名 ×9** | `BridgeMessageHandler.swift:20,27,29`（switch）、`WebviewBridgeClient.swift:61-64,229-230,239`（add/remove）——`"onPromiseResult"` 等字面量 | 已提为 `BridgeHandlerName` 枚举（rawValue 统一；JS 适配脚本内字符串仍为字面量） |

> 注：2.2 各项均为「门面 + 工具分层」未彻底时的典型残留；`DidDocumentEditor`/`DidCredentialHelper`
> 已抽纯函数（做得对），本轮把调用侧各自内联的同款变换与字面量一并收敛。

## 三、Sendable / 并发审计（跨模块汇总）

> ✅ **已全部落地（2025-08-22）**：见下。

**公开 Error 枚举缺 `Sendable`（4 个 + 2 个 internal）** —— ✅ 已补齐：
`DAppConnectError`（`Models.swift:16`）、`SwiftDidError`（`DidModels.swift:204`）、`VaultError`（`VaultModels.swift:32`）、`SwiftWalletError`（`SwiftWallet.swift:239`）；internal：`ChecksumError`、`CredentialDataError`——全部补 `Sendable`（payload 均为 Sendable 标量，纯前瞻性）。

**`@unchecked Sendable` / `nonisolated(unsafe)` 审计：**

| 类型 | 判定 |
|---|---|
| `GRDBAccountStore` / `GRDBDidStore` / `GRDBNftStore` | ✅ 合理（GRDB `DatabasePool` 线程安全）——已补「为什么安全」注释 |
| `RedirectPolicyDelegate`（`NftHttpClient.swift:119`，原 `NoRedirectDelegate`） | ✅ 无状态——已补注释 |
| `BridgeDidResolver`（`DidResolver.swift:11`） | ✅ 已改 `@MainActor`（隐式 Sendable），**去掉 `@unchecked`** |
| `ContinuationBox` / `ReadyWaitBox`（`ContinuationBox.swift:6,23`） | ✅ 已修复（P0-2：onCancel 跳主线程 + box 加锁） |
| `TinkVaultCipher`（`TinkVaultCipher.swift:6`） | ✅ 确认安全：仅供 `VaultRepository` actor 使用，`cachedHandle` 无并发访问——已补注释 |
| `SsrfGuard.enabled`（`SsrfGuard.swift:17`） | ✅ 已补注释：仅 DEBUG 测试一次性设置、无并发读写 |

## 四、架构层观察

1. **错误吞掉是全库系统性模式**，非单点：SwiftDid 写 API→`Bool`、SwiftNft `fetchMetadataFields`→`.empty`、SwiftWallet `buildSwtcNftTransfer`→`[:]`、SwiftAccount `persistVault`→`try?`（✅ 已修复，见 P0-5）、Vault 导入重复→静默 continue。建议定一条统一策略（公开 API 一律 `throws` 或带 `Result`，内部再决定是否降级），否则错误可观测性会持续恶化。
2. ✅ **地址规范化策略（已收敛比较层）**：`VaultRepository.normalizedAddress`（`lowercased()`）、
   `EthMiddleware` 三处 `caseInsensitiveCompare`、`VaultModels.AddressableRecord.matches` 已统一到
   SwiftCore `String.addressEquals` / `normalizedAddress`（SwiftVault 补 SwiftCore 依赖）。
   **剩余**：GRDB `LOWER(address)`（SQL 侧，与「存储层统一小写 + 索引」同属存储/索引项 C-1，
   待 GRDB 表达式索引一并处理）；`WebOrigin.normalize` 是 URL origin 归一（scheme/host/端口），
   与链上地址语义无关，本就该独立保留。
3. ✅ **桥抽象半途而废（已修复）**：`EngineBridge` 协议**已声明 `start() throws`**（`WebviewBridgeEngine.swift:10`），
   但 `SwiftDid.start()` 旧实现只对具体类型 `WebviewBridgeEngine` 调 `start()`（`SwiftDid.swift:65-67`）——
   宿主注入的自定义 `EngineBridge` 会被**静默跳过**、永不启动（而 `destroy()` 走协议无条件调用，不对称）。
   已改为 `try self.bridge.start()` 协议统一启动（与 `SwiftWallet.start()` 同款），删除具体类型特判，
   新增回归测试 `testStartInvokesBridgeStartExactlyOnce`（自定义桥必须被启动 + SwiftDid 幂等）。
4. ✅ **模块名=类名冲突（已修复）**：`SwiftNft` 门面类更名为 `NftClient`——实测「模块与类同名时
   `ModA.Other` 限定引用失败（'Other' is not a member type of class）」，类会遮蔽模块名；
   改名后 `SwiftNft.Nft` 限定拼写恢复可用，`SwiftDid.swift:9-13` 的规避注释已删除。
   ⚠️ **SwiftWallet / SwiftDid 存在同样的潜伏同名**（模块 `SwiftWallet`/`SwiftDid` + 门面类同名），
   但从未被触发：宿主/演示只用门面类本身（`SwiftWallet()` / `SwiftDid(...)` / 类静态成员
   `SwiftWallet.shared`），无任何 `SwiftWallet.<其他类型>` / `SwiftDid.<其他类型>` 模块限定引用
   （遮蔽只在「需要模块限定引用其他类型」时生效）。如需彻底消除，可将门面类更名
   （SwiftDid 门面为模块主 API，属破坏性变更，建议与命名批一并评估）。

## 五、第二轮结论

- 第一轮 P0 六项**全部维持**（P0-1 Vault 访问控制已在第二轮复验；**P0-2 / P0-3 Bridge、P0-4 Nft 溢出、P0-5 Account 吞错、P0-6 Did 过期 fail-open 已修复**，见修复记录）。
- 第一轮有两处**事实性错误已被纠正**（`try append`、`VaultKeyDeriver` Sendable）。
- 新增最关键的正面结论：**代码库在 Swift 6 严格并发下零编译告警零错误**——并发/Sendable 纪律的编译器级验证通过。
- 新增一批跨模块去重与架构一致性建议（表二~四），这些是单模块审查无法发现的。
