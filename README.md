# swift-toolkits

Swift toolkits for iOS. The first module in this repository is a Swift vault SDK that mirrors the core behavior of the Kotlin `vault` module from `kotlin-toolkits`.

## Swift Vault SDK

The Swift implementation provides a `VaultRepository` with the same core responsibilities as the Kotlin version:

- initialize and verify a master password
- unlock and lock an in-memory vault session
- import private keys, mnemonics, secrets, and batch private keys
- rotate the master password by re-encrypting stored entries
- read, remove, and clear persisted vault data

The default storage format is a local protobuf file, while encryption uses `CryptoKit` AES-GCM by default and the default KDF is Argon2id through a Swift package dependency.

## Module Layout

The SDK now follows a vault-oriented module split under `Sources/swift-toolkits/vault`:

- `vault/model`: public models and internal snapshot records
- `vault/repository`: `VaultRepository` orchestration and session lifecycle
- `vault/security`: pluggable cipher and key derivation abstractions
- `vault/storage`: pluggable persistence drivers

This makes it possible to swap the crypto backend or storage backend without changing the repository API.

The default persistence driver is protobuf-backed and writes `vault.pb`.

## Package

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-toolkits.git", branch: "main")
]
```

Import the library as:

```swift
import SwiftVault
```

## Quick Start

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

## Main APIs

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

## Notes

- The current Swift SDK intentionally matches the Kotlin module's repository-level behavior, not its Android-specific storage stack.
- The package now exposes `VaultCipher`, `VaultKeyDeriver`, and `VaultStoreDriver` so you can substitute Tink, Argon2id, or alternate storage backends at the module boundary.
- `SwiftProtobuf` and `Argon2Swift` are integrated directly through `Package.swift`; no `brew` installation is required.
- The default KDF implementation is `Argon2idVaultKeyDeriver`; the old PBKDF2 fallback has been removed to keep the SDK behavior aligned with the Kotlin vault module.

## Tink Obj-C Integration

`SwiftVault` keeps Tink integration optional so the SDK still builds without a checked-in binary. The repository contains:

- `vault/security/TinkVaultCipher.swift`: a conditional adapter compiled only when the `Tink` module is available
- `Vendor/Tink/README.md`: the expected place to vendor a compiled `Tink.xcframework`

Recommended integration flow for SDK distribution:

1. Build `tink-objc` into `Tink.xcframework` outside this repository.
2. Add the binary to `Vendor/Tink/Tink.xcframework` before resolving package dependencies.
3. `Package.swift` will automatically add the local `Tink` binary target when that framework exists.
4. The SDK can then use `TinkVaultCipher(...)` explicitly, and will default to Tink when the `Tink` module is available.

Reusable build script:

```bash
./Scripts/build_tink_xcframework.sh
```

The Tink xcframework used in this repository was built from source with a local Bazelisk binary and a linker-flag compatibility patch to `tink-objc`'s `postprocess_xcframework.sh` for modern Xcode `ld` behavior.

Local build outline:

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

Example:

```swift
import Foundation
import SwiftVault

let repository = VaultRepository(
    storageURL: customVaultURL,
    cipher: TinkVaultCipher(keysetName: "com.example.vault.aead")
)
```

Minimal third-party integration walkthrough:

[Examples/MinimalIntegration/README.md](/Users/musheng/ios/swift-toolkits/Examples/MinimalIntegration/README.md)

## Webview Bridge（Swift 设计稿）

`webview-bridge` 模块的 Swift 移植设计，对齐 Kotlin 版「隐藏 WebView 运行时 + JS Promise 通信」能力（`WKWebView` + `WKScriptMessageHandler`），包含架构解析、完整 Swift 代码草案、通信协议与测试策略：

[Docs/WebviewBridge-Swift/README.md](Docs/WebviewBridge-Swift/README.md)

## Validation

```bash
swift test
```

Validated iOS simulator command for the vendored Tink path:

```bash
xcodebuild test \
    -skipPackagePluginValidation \
    -scheme swift-toolkits \
    -destination 'id={id}'
```
