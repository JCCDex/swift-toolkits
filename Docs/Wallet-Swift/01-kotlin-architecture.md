# 01 · Kotlin 版架构

## 1. 模块定位

`:wallet` 提供钱包相关的 WebView Bridge 能力：助记词生成/校验、派生子账户、从私钥/助记词派生地址、地址校验、签名与验签。它**不持有密钥存储**（那是 `:vault` 的职责），只负责「调用钱包 JS 完成密码学操作」。

## 2. 文件与类

| 文件 | 类 | 职责 |
| --- | --- | --- |
| `WalletSdk.kt` | `object WalletSdk` | 唯一入口：`initialize(context)` / `start()` / `destroy()` + 23 个类型化方法 |
| `AndroidWalletWebRuntime.kt` | `IWalletBridge`（接口） | 桥抽象：`start` / `call` / `callAs` / `destroy` |
| `AndroidWalletWebRuntime.kt` | `AndroidWalletWebRuntime` | 隐藏 WebView 实现：构造时 `initialize + start` 并加载 `wallet-bridge.html` |
| `AndroidWalletWebRuntime.kt` | `IWalletWebBridgeClient` / `RealWalletWebBridgeClient` | 对 `WebviewBridgeClient` 的薄封装（测试可注入 Fake） |
| `WalletModels.kt` | 6 个数据类 | `Keypair` / `Path` / `Mnemonic` / `SubWallet` / `GenerateHDWalletResult` / `TraditionalDeriveResult` |

## 3. WalletSdk 全量 API

### 3.1 生命周期

| 方法 | 说明 |
| --- | --- |
| `initialize(context)` | 幂等；首次创建隐藏 WebView 运行时 |
| `start()` | 启动桥（就绪检测） |
| `destroy()` | 销毁桥并置空（可重建） |
| `callJsMethod(method:params:timeoutMs:readyWaitMs)` | 底层调用，返回 JS 结果字符串 |
| `callJsMethodAs(method:params:clazz:...)` | 底层调用，Gson 反序列化为类型 |

默认超时：`timeoutMs = 30_000`，`readyWaitMs = 15_000`。

### 3.2 助记词 / 派生

| 方法 | JS 方法 | 返回 |
| --- | --- | --- |
| `validateMnemonic(mnemonic, language="english")` | `validateMnemonic` | `Boolean` |
| `generateMnemonic(length=128, language="english")` | `generateMnemonic` | `Mnemonic {value, language}` |
| `deriveChild(mnemonic, chain: Long, account, change, index, language)` | `deriveChild` | `SubWallet {chain, address, path, keypair}` |
| `hdWalletFromMnemonic(mnemonic, chains: List<Long>, language)` | `hdWalletFromMnemonic` | `GenerateHDWalletResult` |
| `deriveFromMnemonic(mnemonic, chain, account, change, index, language)` | `deriveFromMnemonic` | `TraditionalDeriveResult` |
| `deriveFromPrivateKey(privateKey, chain)` | `deriveFromPrivateKey` | `TraditionalDeriveResult` |
| `validatePrivateKey(privateKey, chain)` | `validatePrivateKey` | `Boolean` |

### 3.3 SWTC 交易构造 / 签名

| 方法 | JS 方法 | 返回 |
| --- | --- | --- |
| `buildSwtcPayment(address, amount, to, token, memo)` | `buildSwtcPayment` | `String` |
| `buildSwtcNftTransfer(address, to, tokenId, memo)` | `buildSwtcNftTransfer` | `String` |
| `buildSwtcCreateOrder(address, amount, base, counter, sum, type, platform?, issuer?)` | `buildSwtcCreateOrder` | `String` |
| `buildSwtcCancelOrder(address, sequence)` | `buildSwtcCancelOrder` | `String` |
| `signSwtcTransaction(tx, secret)` | `signSwtcTransaction` | `String`（blob） |
| `isValidAddress(address)` | `isValidAddress` | `Boolean` |
| `signMessage(address, message, secret)` | `signMessage` | `String` |
| `signTransaction(tx, secret)` | `signTransaction` | `String`（blob） |
| `multiSign(tx, secret)` | `multiSign` | `String` |

### 3.4 EVM 签名 / 验签

| 方法 | JS 方法 | 返回 |
| --- | --- | --- |
| `personalSign(privateKey, data)` | `personalSign` | `String` |
| `signTypedData(privateKey, data, version)` | `signTypedData` | `String` |
| `recoverTypedSignature(data, signature, version)` | `recoverTypedSignature` | `String` |
| `recoverPersonalSignature(data, signature)` | `recoverPersonalSignature` | `String` |
| `getEncryptionPublicKey(privateKey)` | `getEncryptionPublicKey` | `String` |
| `decrypt(privateKey, data)` | `decrypt` | `String` |
| `signEthTransaction(privateKey, tx)` | `signEthTransaction` | `String` |

## 4. 模型

```kotlin
data class Keypair(val privateKey: String, val publicKey: String)

data class Path(val chain: Long, val account: Int = 0, val change: Int = 0, val index: Int = 0) {
    override fun toString() = "m/44'/$chain'/$account'/$change/$index"
}

data class Mnemonic(val value: String, val language: String)

data class SubWallet(val chain: Long, val address: String, val path: Path, val keypair: Keypair)

data class GenerateHDWalletResult(
    val mnemonic: String, val address: String, val language: String,
    val keypair: Keypair, val accounts: List<SubWallet> = emptyList()
)

data class TraditionalDeriveResult(
    val address: String, val keypair: Keypair, val mnemonic: Mnemonic? = null,
    val secret: String? = null, val path: Path? = null, val sourcePrivateKey: String? = null
)
```

## 5. 测试基线

- `WalletModelsTest`：模型序列化 / toString。
- `WalletSdkTest`：Fake `IWalletBridge` 注入（`installBridgeForTest`），验证参数构造、返回解析、未初始化抛错。
- `AndroidWalletWebRuntimeTest`：Fake client 注入（`clientFactory`），验证生命周期。
- `RealWalletWebBridgeClientTest`：真实隐藏 WebView 冒烟（`./gradlew :wallet:testDebugUnitTest`）。
