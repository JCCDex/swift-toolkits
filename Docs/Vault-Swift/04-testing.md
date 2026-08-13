# 04 · 测试策略

## 1. 框架与运行方式

- 使用 Swift Testing（`@Test`），异步用例直接 `async throws` 调 actor。
- 本地 / CI：macOS 41 用例、iOS 模拟器 73 用例，覆盖率约 96%（SwiftVault）。
- 运行入口统一走 fastlane（脚本见 `fastlane/Fastfile`，首次需 `bundle install`）：

```bash
# 全部测试：macOS + iOS 模拟器（带覆盖率）
bundle exec fastlane all_tests

# 分别运行
bundle exec fastlane macos_test                                        # macOS（带覆盖率）
bundle exec fastlane ios_test                                          # iOS 模拟器（默认最新运行时）
bundle exec fastlane ios_test "device_name:iPhone 16" device_os:26     # 指定版本/机型
bundle exec fastlane ios_test_only                                     # 仅测试、不带覆盖率（快速路径）
```

- iOS 流程会自动预热模拟器（`simctl bootstatus -b`）、串行执行（`-parallel-testing-enabled NO`），并对失败用例自动重试一次（`-retry-tests-on-failure` + `-test-iterations 2`），产出 xcresult 与 lcov/HTML 报告。

## 2. 用例分类

### 生命周期与密码

- 单例缓存（`VaultRepository.get() === VaultRepository.get()`）
- `initializePassword` / `verifyPassword` / `hasPassword` / 未初始化幂等
- `unlock` / `lock` / `isUnlocked` 往返；`unlock works without persisted derived key`
- 错误密码路径：锁定态读取、移除、改密均抛 `wrongPassword`

### 导入与去重

- 私钥 / 助记词 / 秘钥：首次导入 → 读回一致
- 重复导入（同地址、不同数据）静默忽略并保留首条
- 大小写不敏感去重（`0xABC` vs `0xabc`）
- 批量导入跳过已存在地址；空数组 no-op

### 助记词元数据

- 英文 / 中文助记词往返，`language` 与 `derivationPath` 保留（`chinese_simplified`、`m/44'/315'/0'/0/0`）
- `getMnemonicLanguage` 对无助记词地址抛 `mnemonicNotFound`

### 维护操作

- `changePassword` 全量重加密迁移（多地址、中英文助记词、秘钥），旧密码失效
- `removeAddress` 三表联动移除；`listAccounts` 正确
- `clearAllData` 密码门禁（错误密码抛错、正确密码/无密码可清空）

### 生物识别

- `hasBiometric` / `getBiometric` / `updateBiometric` / `clearBiometric` 生命周期；未设置抛 `biometricNotFound`

### 安全原语

- `wipe()` 对 `[UInt8]` / `[Character]` / `Data` 清零；空数组 no-op
- `Argon2ParamChooser` 返回正参数（默认 / 大堆两种模式）
- HMAC proof 校验与改密后 proof 迁移
- CryptoKit 截断密文抛错

### 存储

- protobuf 空 vault 序列化往返
- 存储驱动文件缺失 → 空快照

### 双后端

- `#if canImport(Tink)` 包裹 Tink 用例：
  - Tink 密文不透明（`iv` 空、ciphertext 非空）且可往返
  - iOS 上 Tink 后端写出的 protobuf 中 `iv` 为空
  - Tink 仓库完整往返（解锁/读回）
- 每个 Tink 用例使用独立 `keysetName`（`UUID` 后缀）避免 keychain 冲突；`persistKeysetInKeychain: false` 用于临时测试

## 3. 测试基建

```swift
private func makeRepository(cipher: (any VaultCipher)? = nil) -> VaultRepository {
    VaultRepository(storageURL: makeTemporaryVaultURL(), cipher: cipher)
}
```

- 所有用例用临时文件 URL，互不污染，也不需要清理生产路径。
- `seededRepository()` 预置「已初始化密码 + 若干条目」的仓库，聚焦单一行为。
- Tink / Keychain 相关用例在 iOS 模拟器与 macOS 上的可用性用编译期条件区分。

## 4. 覆盖率与 CI

覆盖率由 fastlane 的 `macos_test` / `ios_test` lane 负责：内部以 `xcodebuild -enableCodeCoverage` 收集 xcresult，再交给 xcov 生成 HTML/JSON/Markdown 报告；测试 target 计入忽略清单（`.xcovignore`）。

CI（`.github/workflows/ci.yml`）矩阵覆盖 iOS 18 / iOS 26 两个主流版本，与 Webview Bridge 共用同一工作流，调用形式：

```bash
bundle exec fastlane ios_test "device_name:iPhone 16" device_os:18
bundle exec fastlane ios_test "device_name:iPhone 16e" device_os:26
```
