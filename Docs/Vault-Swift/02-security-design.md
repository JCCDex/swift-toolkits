# 02 · 安全设计

## 1. 威胁模型与目标

- 静态存储文件被窃取时，攻击者无法还原任何明文（私钥/助记词/秘钥）。
- 密码不以明文/可逆形式持久化；离线暴力破解受 Argon2id 内存与时间成本约束。
- 密文绑定记录类型与地址（AAD），防止「同一密钥下密文互换/搬家」攻击。
- 密码校验不泄露时序信息（常量时间比较）。

## 2. 密钥派生（KDF）

默认实现 `Argon2idVaultKeyDeriver`：

```swift
let result = try Argon2Swift.hashPasswordBytes(
    password: password,
    salt: Salt(bytes: salt),
    iterations: parameters.iterations,   // 默认 3
    memory: parameters.memoryKiB,        // 默认 64 MiB
    parallelism: parameters.parallelism, // 默认 1
    length: parameters.keyByteCount,     // 默认 32
    type: .id,
    version: .V13
)
```

`Argon2ParamChooser` 按设备物理内存自适应：

| 模式 | 内存目标 | 范围 |
| --- | --- | --- |
| 默认 | `memory/16` | 32 ~ 128 MiB |
| `preferLargeHeap` | `memory/8` | 64 ~ 256 MiB |

派生结果**只作为内存会话密钥**，落盘仅保存 salt 与参数，不保存派生密钥。

## 3. 密码 proof

```swift
private static let proofDomainSeparator = Data("CCDAO_VAULT_V1_PASSWORD_PROOF".utf8)

// proof = HMAC-SHA256(key, domainSeparator)
let mac = HMAC<SHA256>.authenticationCode(
    for: Self.proofDomainSeparator,
    using: SymmetricKey(data: key)
)
```

- 校验使用 `constantTimeEquals`：逐字节异或累积，先比长度，不提前短路。
- proof 随信封一起持久化（`PasswordEntry.proof_ct`），用于 `verifyPassword` / `unlock` 的密码正确性判断。

## 4. 加密后端（VaultCipher）

### CryptoKitVaultCipher（默认）

AES-256-GCM，密钥 32B：

```swift
let sealedBox = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
let nonce = Data(sealedBox.nonce)                      // 12B
let ciphertext = sealedBox.ciphertext + sealedBox.tag  // 密文 + 16B tag
```

解密时按尾部 16B 拆分 tag，`ciphertext.count < 16` 抛错（截断检测）。AAD 校验失败由 GCM 认证兜底。

### TinkVaultCipher（可选）

- `#if canImport(Tink)` 条件编译，编译期决定。
- 使用 Tink AES256-GCM keyset；默认 `persistKeysetInKeychain: true`，keyset 写入 keychain（`overwrite: false`），进程内缓存 handle。
- `encrypt` 忽略入参 `key`（密钥在 keyset 内）；产物 `iv` 为空、`ciphertext` 为 Tink 不透明密文（nonce 内嵌），与 CryptoKit 格式不可互换。
- 模拟器上默认 `persistKeysetInKeychain: false`（keychain 语义差异，见 `defaultCipher()` 的平台分支）。

## 5. AAD 绑定

| 数据 | AAD |
| --- | --- |
| 密码信封 | `"vault:v1"`（存于 `envelope.aad`） |
| 私钥条目 | `"address:<lowercased(address)>"` |
| 助记词条目 | `"mnemonic:<lowercased(address)>"` |
| 秘钥条目 | `"secret:<lowercased(address)>"` |

地址统一小写归一化后再进 AAD，与去重规则（大小写不敏感）保持一致。

## 6. 会话密钥生命周期

- `sessionKey: Data?` 仅存于 actor 内存；`initializePassword` / `unlock` 写入，`lock()` / `clearAllData` 置空。
- 读取、移除、改密都要求有效会话（`ensureUnlocked`）。
- Swift 无法保证 `Data` 释放即清零，仓库提供 `Wipe.swift` 扩展（`Data`/`[UInt8]`/`[Character]` 就地清零），供上层对敏感缓冲区主动擦除；仓库内部不隐式调用，避免覆盖优化导致不可靠。

## 7. 设计取舍与注意点

- **不持久化派生密钥**：每次解锁重新 KDF，安全优先于速度。
- **双后端格式不同**：Tink 密文对 CryptoKit 不透明，切换后端意味着历史数据需迁移或重建。
- **biometric 不参与本模块加密**：仓库仅存取密文，密钥策略由上层负责。
- **改密清空 biometric**：`changePassword` 的新快照不含 biometric 字段，属于当前实现的有意行为。

