# Vault · Swift 设计文档

本文档描述 `swift-toolkits` 中 `SwiftVault` 模块的设计与实现，目标是把 `kotlin-toolkits` 的 `vault` 模块能力以 Swift/iOS 惯用方式复刻：密码初始化与验证、会话解锁/锁定、私钥/助记词/秘钥的加密持久化、批量导入、密码轮换、地址移除与清空。

> 状态：已实现（Swift 6.2，iOS 15+ / macOS 13+），随 CI 双平台验证；文中代码为当前实现的结构化描述。

## 设计原则

1. **行为对齐**：密码 proof、地址去重（大小写不敏感）、重复导入静默忽略、改密全量重加密、锁后必须重新解锁等行为与 Kotlin `vault` 模块契约一致。
2. **可插拔后端**：加密（`VaultCipher`）、密钥派生（`VaultKeyDeriver`）、持久化（`VaultStoreDriver`）都是协议抽象，仓库 API 不依赖具体实现，可替换为 Tink / CryptoKit / 任意存储。
3. **默认安全**：默认 Argon2id 派生 + AES-256-GCM 认证加密；密码 proof 用 HMAC-SHA256 并以常量时间比较；所有密文绑定 AAD，防地址互换/重放。
4. **Swift 并发**：`VaultRepository` 是 `actor`，会话密钥只存在于内存，`lock()` 即置空；文件读写与派生都在 actor 内串行执行。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-architecture.md](01-architecture.md) | 模块布局、核心类型、协议抽象、关键流程（初始化/解锁/导入/改密/清空）、地址去重与错误模型 |
| [02-security-design.md](02-security-design.md) | 安全设计：Argon2id 参数与自适应选择、AES-GCM/Tink 双后端、密码 proof、AAD 绑定、会话密钥生命周期、数据擦除 |
| [03-storage-format.md](03-storage-format.md) | protobuf 存储格式：消息结构、字段映射、文件位置、原子写入与兼容性说明 |
| [04-testing.md](04-testing.md) | 测试策略：Swift Testing 用例分类、行为契约清单、双后端与 CI 覆盖 |

## 快速接入

```swift
import Foundation
import SwiftVault

let vault = VaultRepository.get()
let password = Data("strong-password".utf8)

// 首次：初始化主密码（之后自动进入解锁态）
try await vault.initializePassword(password)

// 导入私钥（未初始化或重复地址会被静默忽略）
try await vault.importPrivateKey(
    address: "0x1234...",
    privateKey: Data("0xabc123...".utf8)
)

// 读取需要密码（锁定态先解锁，解锁态会再校验一次）
let restored = try await vault.getPrivateKey(
    address: "0x1234...",
    password: password
)

// 切换后端（例如自定义存储位置 + Tink）
let customVault = VaultRepository(
    storageURL: customVaultURL,
    cipher: TinkVaultCipher(keysetName: "com.example.vault.aead")
)
```

## 主要 API

| 类别 | API |
| --- | --- |
| 密码 | `initializePassword(_:parameters:)`、`verifyPassword(_:)`、`hasPassword()` |
| 会话 | `unlock(_:)`、`lock()`、`isUnlocked` |
| 导入 | `importPrivateKey(address:privateKey:)`、`importPrivateKeys(_:)`、`importMnemonic(address:mnemonic:privateKey:pathPrefix:language:)`、`importSecret(address:privateKey:secret:)` |
| 读取 | `getPrivateKey(address:password:)`、`getMnemonic(address:password:)`、`getSecret(address:password:)`、`getMnemonicLanguage(address:)`、`listAccounts()`、`addressInKeys/Mnemonics/Secrets(_:)` |
| 维护 | `changePassword(oldPassword:newPassword:parameters:)`、`removeAddress(address:password:)`、`clearAllData(password:)` |
| 生物识别 | `hasBiometric()`、`getBiometric()`、`updateBiometric(ciphertext:iv:)`、`clearBiometric()` |

## Swift 侧关键设计

| 维度 | 设计 |
| --- | --- |
| 并发 | `actor VaultRepository`（替代 Kotlin 的同步 + 锁） |
| 默认加密 | `CryptoKitVaultCipher`：AES-256-GCM，nonce + ciphertext + tag，AAD 绑定 |
| 可选加密 | `TinkVaultCipher`：Tink AES256-GCM keyset，keychain 持久化，密文不透明（无独立 IV） |
| 密钥派生 | `Argon2idVaultKeyDeriver`（Argon2id v1.3），参数可经 `Argon2ParamChooser` 按内存自适应 |
| 存储 | `ProtobufVaultStoreDriver`：`Application Support/SwiftVault/vault.pb`，原子写入 |
| 密码校验 | HMAC-SHA256 proof + 常量时间比较，不解持久化派生密钥 |
| 擦除 | `Wipe.swift` 提供 `Data`/`[UInt8]`/`[Character]` 的清零扩展 |
