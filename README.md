# swift-toolkits

[![CI](https://github.com/JCCDex/swift-toolkits/actions/workflows/ci.yml/badge.svg)](https://github.com/JCCDex/swift-toolkits/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/JCCDex/swift-toolkits/branch/main/graph/badge.svg)](https://codecov.io/gh/JCCDex/swift-toolkits)

面向 iOS 的 Swift 工具库。仓库包含：镜像 `kotlin-toolkits` 中 `vault` 模块核心行为的 Swift 保险库 SDK，以及 Kotlin `webview-bridge` 模块的 Swift 移植（见下文）。

## SwiftVault

Vault SDK：功能介绍、快速开始、API、Tink 集成等详见：

[SwiftVault/README.md](Sources/SwiftVault/README.md)

## SwiftWebviewBridge

Webview Bridge：Swift 移植设计、快速接入、协议说明与测试策略详见：

[SwiftWebviewBridge/README.md](Sources/SwiftWebviewBridge/README.md)

## 测试

测试统一通过 fastlane 运行（脚本见 `fastlane/Fastfile`，首次需 `bundle install`）：

```bash
# 全部测试：macOS + iOS 模拟器（带覆盖率）
bundle exec fastlane all_tests

# 分别运行
bundle exec fastlane macos_test                          # macOS（带覆盖率）
bundle exec fastlane ios_test                            # iOS 模拟器（默认最新运行时）
bundle exec fastlane ios_test "device_name:iPhone 16" device_os:18   # 指定版本/机型（与 CI 一致）
bundle exec fastlane ios_test_only                       # 仅测试、不带覆盖率（快速路径）
```

说明：iOS 测试会自动预热模拟器、串行执行，并对失败用例自动重试一次；覆盖率报告输出到 `coverage/`。

> Tink 相关用例：Tink.xcframework 未 vendored 时相关用例会被编译期条件跳过，不影响其余测试。
