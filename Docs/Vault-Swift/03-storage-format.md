# 03 · 存储格式

## 1. 文件位置

默认路径：

```swift
// Application Support/SwiftVault/vault.pb
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    .first!.appendingPathComponent("SwiftVault", isDirectory: true)
    .appendingPathComponent("vault.pb")
```

写入前 `createDirectory(withIntermediateDirectories: true)`，落盘用 `write(to:options: .atomic)`，避免半写文件。

## 2. protobuf schema

```protobuf
syntax = "proto3";

message PrivateKeyEntry { string address = 1; bytes iv = 2; bytes ciphertext = 3; }
message SecretEntry    { string address = 1; bytes iv = 2; bytes ciphertext = 3; }

message MnemonicEntry {
  string address = 1;
  bytes iv = 2;
  bytes ciphertext = 3;
  string lang = 4;             // 语言（english / chinese_simplified ...）
  string hint = 5;             // 预留
  string derivation_path = 6;  // 默认 m/44'/60'/0'/0/0
}

message PasswordEntry {
  bytes salt = 1;
  int32 iterations = 2;
  int32 memory_kib = 3;
  int32 parallelism = 4;
  bytes aad = 5;          // "vault:v1"
  bytes proof_iv = 6;     // 预留（当前 proof 为 HMAC，无 IV）
  bytes proof_ct = 7;     // HMAC-SHA256 proof
  bool has_biometric_cache = 8;  // 预留
  int32 key_byte_count = 9;
}

message BiometricEntry { bytes iv = 1; bytes ciphertext = 2; }

message Vault {
  repeated PrivateKeyEntry keys = 1;
  repeated MnemonicEntry mnemonics = 2;
  PasswordEntry password = 3;
  repeated SecretEntry secrets = 5;
  BiometricEntry biometric = 6;
}
```

字段 `4` 在 `Vault` 中留空（proto3 演进预留）。

## 3. Swift 映射

| protobuf | Swift 快照 |
| --- | --- |
| `Vault.password` | `PasswordEnvelope?` |
| `Vault.keys[]` | `[VaultEncryptedRecord]` |
| `Vault.mnemonics[]` | `[VaultMnemonicRecord]`（`lang`→`language`，`derivation_path`→`derivationPath`） |
| `Vault.secrets[]` | `[VaultEncryptedRecord]` |
| `Vault.biometric` | `VaultSealedPayload?`（iv 与 ciphertext 均空视为无） |
| `PasswordEntry.proof_ct` | `PasswordEnvelope.proof` |

读取兼容性规则：

- 文件不存在 → 返回空 `VaultStoreSnapshot`（首次使用无需预创建）。
- `key_byte_count == 0` 的历史数据按 32B 处理。
- `PasswordEntry` 判定「是否存在」以 `salt` 与 `proof_ct` 是否均空为准。
- `iv`/`ciphertext` 均空的 `BiometricEntry` 视为未设置。

## 4. 与加密后端的关系

`VaultSealedPayload` 与格式解耦：

- CryptoKit 后端：`iv` = 12B nonce，`ciphertext` = 密文 + 16B tag。
- Tink 后端：`iv` 为空，`ciphertext` 为 Tink 不透明密文（nonce 内嵌）。

同一 `vault.pb` 文件由哪个后端写出，读取时也需用同一后端；混用会因格式不兼容而解密失败。

## 5. 生成方式

proto 由 SwiftProtobuf 插件生成（`swift-protobuf-config.json` 指定 `proto/private_key_vault.proto`，`visibility: Internal`，`fileNaming: DropPath`），生成类型仅模块内部可见，对外暴露的是快照模型与仓库 API。

