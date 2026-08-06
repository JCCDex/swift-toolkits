# Minimal SwiftVault Integration

This example shows the smallest practical setup for a third-party iOS project that wants to consume `SwiftVault` with the vendored `Tink.xcframework`.

## 1. Add the package

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-toolkits.git", branch: "main")
]
```

The package will automatically register the local binary target when `Vendor/Tink/Tink.xcframework` exists inside the checked-out package directory.

## 2. Build and vendor Tink

From the package root:

```bash
./Scripts/build_tink_xcframework.sh
```

That script:

- clones `tink-objc`
- downloads `bazelisk` if needed
- applies the local linker-compatibility patch for current Xcode toolchains
- builds `//Tink:Tink_static_xcframework`
- unzips the result into `Vendor/Tink/Tink.xcframework`

## 3. Use SwiftVault in app code

```swift
import Foundation
import SwiftVault

let vaultURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MyApp/vault.pb")

let repository = VaultRepository(
    storageURL: vaultURL,
    cipher: TinkVaultCipher(keysetName: "com.example.myapp.vault.aead")
)

let password = Data("strong-password".utf8)
let privateKey = Data("0xabc123".utf8)

try await repository.initializePassword(password)
try await repository.importPrivateKey(address: "0x1234", privateKey: privateKey)

let restored = try await repository.getPrivateKey(address: "0x1234", password: password)
```

## 4. Validate locally

macOS package tests:

```bash
swift test
```

iOS simulator validation with vendored Tink:

```bash
xcodebuild test \
  -skipPackagePluginValidation \
  -scheme swift-toolkits \
  -destination 'id=C134E373-289E-4BD0-B4CD-11C1EC2070B0'
```

## Notes

- `VaultRepository` defaults to `TinkVaultCipher` only when the `Tink` module is importable.
- On simulator/test paths, `TinkVaultCipher` can be configured with `persistKeysetInKeychain: false` to avoid keychain entitlement failures.
- The default persistence format remains protobuf at `vault.pb`.
