# SwiftVault

Swift vault SDK，镜像 `kotlin-toolkits` 中 Kotlin `vault` 模块的核心行为：密码初始化与验证、会话解锁/锁定、私钥/助记词/秘钥的加密持久化、批量导入、密码轮换、地址移除与清空。

## 核心职责

`VaultRepository` 承担与 Kotlin 版本相同的核心职责：

- 初始化并校验主密码
- 解锁 / 锁定内存中的保险库会话
- 导入私钥、助记词、秘钥以及批量私钥
- 通过重新加密已有条目轮换主密码
- 读取、移除与清空已持久化的保险库数据

默认存储格式为本地 protobuf 文件；加密默认使用 `CryptoKit` AES-GCM；KDF 默认使用 Argon2id（Swift 包依赖）。

## 模块结构

本模块按 vault 职责拆分（`Sources/SwiftVault/`）：

- `model`：公开模型与内部快照记录
- `repository`：`VaultRepository` 编排与会话生命周期
- `security`：可插拔的加密与密钥派生抽象
- `storage`：可插拔的持久化驱动
- `util`：敏感数据清零工具
- `proto`：protobuf 存储 schema（由 SwiftProtobuf 插件生成）

加密后端、存储后端与密钥派生均可替换，无需改动仓库 API。默认持久化驱动基于 protobuf，写入 `vault.pb`。

## 接入

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-toolkits.git", branch: "main")
]
```

引入库：

```swift
import SwiftVault
```

## 快速开始

```swift
import Foundation
import SwiftVault

let vault = VaultRepository.get()
let password = Data("strong-password".utf8)

try await vault.initializePassword(password)
try await vault.importPrivateKey(
    address: "0x1234",
    privateKey: Data("0xabc123".utf8)
)

let restored = try await vault.getPrivateKey(
    address: "0x1234",
    password: password
)
```

## 主要 API

- `initializePassword(_:parameters:)`
- `verifyPassword(_:)`
- `unlock(_:)`
- `lock()`
- `importPrivateKey(address:privateKey:)`
- `importMnemonic(address:mnemonic:privateKey:pathPrefix:language:)`
- `importSecret(address:privateKey:secret:)`
- `importPrivateKeys(_:)`
- `changePassword(oldPassword:newPassword:parameters:)`
- `getPrivateKey(address:password:)`
- `getMnemonic(address:password:)`
- `getSecret(address:password:)`
- `removeAddress(address:password:)`
- `clearAllData(password:)`

## 说明

- 当前 Swift SDK 有意对齐 Kotlin 模块的仓库层行为，而非其 Android 专属存储栈。
- 模块暴露 `VaultCipher` / `VaultKeyDeriver` / `VaultStoreDriver`，可在模块边界替换 Tink、Argon2id 或其它存储后端。
- `SwiftProtobuf` 与 `Argon2Swift` 直接通过 `Package.swift` 集成，无需 `brew` 安装。
- 默认 KDF 为 `Argon2idVaultKeyDeriver`；已移除旧 PBKDF2 回退，保持与 Kotlin vault 模块行为一致。

## Tink 集成

`SwiftVault` 将 Tink 集成保持为可选，未携带二进制时 SDK 依然可编译。仓库包含：

- [`security/TinkVaultCipher.swift`](security/TinkVaultCipher.swift)：仅在 `Tink` 模块可用时编译的条件适配器
- [`Vendor/Tink/README.md`](../../Vendor/Tink/README.md)：放置编译好的 `Tink.xcframework` 的预期位置

推荐的集成流程（SDK 分发）：

1. 在仓库外把 `tink-objc` 构建成 `Tink.xcframework`。
2. 解析包依赖前，把二进制放到 `Vendor/Tink/Tink.xcframework`。
3. 框架存在时，`Package.swift` 会自动添加本地 `Tink` 二进制 target。
4. SDK 可显式使用 `TinkVaultCipher(...)`，`Tink` 模块可用时也会默认使用 Tink。

可复用构建脚本：

```bash
../../Scripts/build_tink_xcframework.sh
```

本仓库使用的 `Tink.xcframework` 由源码构建：使用本地 Bazelisk，并对 `tink-objc` 的 `postprocess_xcframework.sh` 打了链接器标志兼容补丁，适配新版 Xcode `ld` 行为。

本地构建步骤：

```bash
cd /tmp
git clone --depth=1 https://github.com/tink-crypto/tink-objc.git tink-objc-build
curl -L https://github.com/bazelbuild/bazelisk/releases/download/v1.29.0/bazelisk-darwin-arm64 -o bazelisk
chmod +x bazelisk
cd tink-objc-build

# patch tools/release/postprocess_xcframework.sh to use:
#   -platform_version ios ...
#   -platform_version ios-simulator ...

/tmp/bazelisk build //Tink:Tink_static_xcframework
unzip -qq bazel-bin/Tink/Tink.xcframework.zip -d /path/to/swift-toolkits/Vendor/Tink
```

示例：

```swift
import Foundation
import SwiftVault

let repository = VaultRepository(
    storageURL: customVaultURL,
    cipher: TinkVaultCipher(keysetName: "com.example.vault.aead")
)
```

最小第三方集成示例：

[Examples/MinimalIntegration/README.md](../../Examples/MinimalIntegration/README.md)

## 设计文档

模块架构、安全设计（Argon2id / AES-GCM / Tink）、protobuf 存储格式与测试策略详见：

[Docs/Vault-Swift/README.md](../../Docs/Vault-Swift/README.md)
