# 01 · 模块架构

## 1. 模块布局

```text
Sources/SwiftVault/
├── repository/
│   └── VaultRepository.swift        // 唯一入口（actor）：生命周期 + 编排
├── model/
│   └── VaultModels.swift            // 公开模型 / 内部快照 / 错误类型
├── security/
│   ├── VaultKeyDeriver.swift        // 密钥派生协议
│   ├── Argon2idVaultKeyDeriver.swift
│   ├── Argon2ParamChooser.swift     // 按物理内存自适应参数
│   ├── VaultCipher.swift            // 加密协议
│   ├── CryptoKitVaultCipher.swift   // 默认实现：AES-256-GCM
│   └── TinkVaultCipher.swift        // 可选实现：Tink AES256-GCM（#if canImport(Tink)）
├── storage/
│   ├── VaultStoreDriver.swift       // 持久化协议
│   └── ProtobufVaultStoreDriver.swift
├── util/
│   └── Wipe.swift                   // 敏感数据清零扩展
├── proto/
│   └── private_key_vault.proto      // protobuf 存储 schema
└── swift-protobuf-config.json       // SwiftProtobuf 插件配置
```

`VaultRepository` 持有三个协议依赖：

```swift
public actor VaultRepository {
    private let store: any VaultStoreDriver
    private let cipher: any VaultCipher
    private let keyDeriver: any VaultKeyDeriver
    private var sessionKey: Data?    // 解锁后的派生密钥，仅存内存
}
```

默认组合：`ProtobufVaultStoreDriver` + `CryptoKitVaultCipher`（Tink 可用时默认切 Tink）+ `Argon2idVaultKeyDeriver`。全部可通过 `init(storageURL:cipher:keyDeriver:)` 注入替换，方便测试与 SDK 分发。

## 2. 核心类型

### 2.1 公开模型

```swift
public struct PasswordKDFParameters: Sendable, Codable, Equatable {
    public var iterations: Int      // 默认 3
    public var memoryKiB: Int       // 默认 64 * 1024（64 MiB）
    public var parallelism: Int     // 默认 1
    public var keyByteCount: Int    // 默认 32
}

public struct VaultPrivateKeyImport: Sendable, Hashable {
    public let address: String
    public let privateKey: Data
}

public struct VaultSealedPayload: Codable, Equatable, Sendable {
    public let iv: Data            // CryptoKit 用 12B nonce；Tink 后端为空
    public let ciphertext: Data    // CryptoKit 为 ciphertext+tag；Tink 为不透明密文
}
```

### 2.2 内部快照

```swift
struct VaultStoreSnapshot: Codable {
    var password: PasswordEnvelope?      // salt / KDF 参数 / aad / proof
    var keys: [VaultEncryptedRecord]     // 私钥
    var mnemonics: [VaultMnemonicRecord] // 助记词（含 derivationPath/language）
    var secrets: [VaultEncryptedRecord]  // 通用秘钥
    var biometric: VaultSealedPayload?   // 生物识别缓存（透传密文，仓库不加密/解密）
}
```

### 2.3 错误模型

```swift
public enum VaultError: Error, Equatable {
    case vaultLocked              // 会话未解锁时内部读取
    case passwordNotInitialized
    case wrongPassword            // 校验失败 / 锁定态解锁失败
    case privateKeyNotFound
    case mnemonicNotFound
    case secretNotFound
    case biometricNotFound
    case tinkUnavailable
}
```

## 3. 关键流程

### 3.1 初始化密码

1. `loadStore()`；若已存在 `password` 信封则返回 `false`（幂等，不覆盖）。
2. 生成 16B 随机 salt，`Argon2id` 派生 32B 密钥。
3. 写 `PasswordEnvelope`：salt、KDF 参数、AAD（`vault:v1`）、proof（HMAC-SHA256，见安全文档）。
4. 原子落盘，`sessionKey = key`，进入解锁态，返回 `true`。

### 3.2 验证 / 解锁

- `verifyPassword`：重新派生密钥，常量时间比较 proof，不改变会话。
- `unlock`：派生密钥 + 校验 proof，成功则 `sessionKey = key`。
- 读取类 API（`getPrivateKey/Mnemonic/Secret`、`removeAddress`、`changePassword`）统一走 `ensureUnlocked(with:)`：已解锁则**再次校验密码**（防越权），未解锁则尝试解锁；失败抛 `wrongPassword`。
- 派生密钥从不持久化，每次解锁都重新计算（`unlock works without persisted derived key`）。

### 3.3 导入与去重

- 地址匹配**大小写不敏感**（`AddressableRecord.matches` 用 `caseInsensitiveCompare`）。
- `importMnemonic` / `importSecret` 内部先调 `importPrivateKey`，再按各自列表去重；重复地址直接静默返回，保留首条数据。
- `importPrivateKeys` 批量导入：单次快照内逐个跳过已存在地址，最后一次性落盘。

### 3.4 密码轮换

1. `ensureUnlocked(old)`；派生新 salt + 新密钥。
2. 逐条解密（旧 key + 各自 AAD）→ 用新 key 重新加密（同 AAD）→ 写入新快照。
3. 落盘后 `sessionKey = newKey`。

> 注意：`changePassword` 构造的新快照**不携带 biometric 字段**，因此改密会清空生物识别缓存。

### 3.5 移除 / 清空

- `removeAddress`：需解锁，从 keys/mnemonics/secrets 三表按大小写不敏感移除后落盘。
- `clearAllData(password:)`：传密码时先 `verifyPassword`，失败抛 `wrongPassword`；随后 `lock()` 并写空快照。无密码版本不做校验（用于「重置保险库」）。

### 3.6 生物识别

`updateBiometric(ciphertext:iv:)` / `getBiometric()` 只做**透传存取**：仓库不持有其密钥、不参与加解密，密文由上层（如 Keychain 或安全隔区派生密钥）生成，仓库仅保证与其它条目一样原子持久化。
