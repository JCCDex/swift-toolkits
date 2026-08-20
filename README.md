# swift-toolkits

[![CI](https://github.com/JCCDex/swift-toolkits/actions/workflows/ci.yml/badge.svg)](https://github.com/JCCDex/swift-toolkits/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/JCCDex/swift-toolkits/branch/main/graph/badge.svg)](https://codecov.io/gh/JCCDex/swift-toolkits)

面向 iOS 的 Swift 工具库。仓库镜像 `kotlin-toolkits` 的多个模块：Swift 保险库 SDK（`vault`）、隐藏 WebView 桥（`webview-bridge`）、DApp 连接（`dapp-connect`）、NFT 元数据/头像解析（`nft`）、DID 文档管理（`did`）、共享模型与钱包账户（`core` / `account`）。

## SwiftCore

共享基础模型：`ChainType`（BIP44 链码/是否为 EVM/SWTC）、`Path`（BIP44 派生路径，含 `derivationPath`/`root`）、`WalletAccount`（账户元数据，`isRootHD`）。详见：

[SwiftCore/README.md](Sources/SwiftCore/README.md)

## SwiftAccount

账户元数据管理与导入编排（镜像 Kotlin `:account`）：`AccountStore` 协议 + `GRDBAccountStore`（`accounts`/`current_account` 表）、`AccountManager` 六条流程（导入单账户 / HD 钱包 / 子账户、派生、删除、清空）、`SwiftAccount` 门面（`accounts`/`currentAccount` 观察流 + `setCurrentAccount`）。密钥经 `SwiftVault` 落库，地址派生经 `WalletDeriving`（`SwiftWallet` 实现）。快速接入与 API 详见：

[SwiftAccount/README.md](Sources/SwiftAccount/README.md)

设计文档（对齐 Kotlin `:account`、GRDB 迁移、协议）：[Docs/Account-Swift/README.md](Docs/Account-Swift/README.md)

## SwiftVault

Vault SDK：功能介绍、快速开始、API、Tink 集成等详见：

[SwiftVault/README.md](Sources/SwiftVault/README.md)

## SwiftWebviewBridge

Webview Bridge：Swift 移植设计、快速接入、协议说明与测试策略详见：

[SwiftWebviewBridge/README.md](Sources/SwiftWebviewBridge/README.md)

## SwiftDappConnect

DApp Connect：Swift 移植设计、快速接入、通信协议与安全说明详见：

[SwiftDappConnect/README.md](Sources/SwiftDappConnect/README.md)

## SwiftNft

NFT 元数据解析与缓存、本地 NFT 持仓存储（GRDB 四表）、DID 头像/凭证图片解析；随包提供 EVM `tokenURI` eth_call 默认解析器（RPC 端点由宿主经 `getRpcNode` 注入，模块不内置）与 SWTC `erc_info` 客户端。快速接入与 API 详见：

[SwiftNft/README.md](Sources/SwiftNft/README.md)

设计文档（对齐 Kotlin `:nft`、GRDB 迁移、协议与安全）：[Docs/Nft-Swift/README.md](Docs/Nft-Swift/README.md)

## SwiftDid

DID 文档解析/管理、Profile/头像 VC、NFT 凭证签发与验证、pending 对账（GRDB 持久化）；经 `SwiftNft` 接入头像解析，并实现 `SwiftDappConnect.DidSDK`。快速接入与 API 详见：

[SwiftDid/README.md](Sources/SwiftDid/README.md)

设计文档（对齐 Kotlin `:did`、桥协议、GRDB 迁移）：[Docs/Did-Swift/README.md](Docs/Did-Swift/README.md)

## 示例 App：WalletDemo

组合演示 SwiftCore / SwiftAccount / SwiftVault / SwiftWallet / SwiftDappConnect / SwiftNft / SwiftDid：钱包生成与密钥查看（列表/当前地址/新增均走 SwiftAccount 的 Account API）、真实 DApp 页（EIP-1193 provider）、DID 头像二级页（缓存优先：文档/元数据/图片逐层落库，已缓存直接出图）。详见：

[Examples/WalletDemo/README.md](Examples/WalletDemo/README.md)

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

# llvm-cov HTML 覆盖率报告（coverage/html/index.html，含全部模块）
bundle exec fastlane html_report
```
