# 02 · Swift 版设计

## 1. 设计目标与取舍

- 保持 Kotlin 的**行为契约**（postMessage 消息格式、nonce 队列、错误码、requestAccounts 强制回调、origin 校验、HD 根过滤），把平台相关部分替换为 WebKit 生态。
- iOS 没有 `addJavascriptInterface` 与 `WebMessagePort` 的等价物：JS→Native 用 `WKUserContentController.add(_:contentWorld:name:)` + legacy `WKScriptMessageHandler`；Native→JS 响应由 native 用 `evaluateJavaScript` 调用 provider 的 `window._ccdaoSettle(nonce, payloadJson, token)` 回传，等价于 Kotlin 的 C-03 端口通道。**弃用 `WKScriptMessageHandlerWithReply`**：其 reply 通道在裸测试进程（macOS/iOS 模拟器）消息能进但回复不送达，而 legacy + evaluateJavaScript 模式与 SwiftWebviewBridge 同款、已验证可用。
- **M1/M2 加固（相对 Kotlin 的显式偏离）**：native → JS 仅保留两个入口 `_ccdaoSettle`（响应）与 `_ccdaoNative`（状态推送），均校验桥接 token（`WebAppInterface.responseToken`，经 `loadProviderJs(token:)` 注入闭包）、冻结为不可写/不可删/不可枚举，且状态收进 IIFE 闭包、不再暴露可写的 `window._ccdaoProviderState`。页面 JS 无 token 且读不到挂起 nonce，无法伪造响应或 `accountsChanged` / `chainChanged` 事件。
- provider JS 的 `requestQueue` 是 IIFE 私有闭包，Swift 侧**不能**在外部注入 settle 函数；因此 iOS 采用同一逻辑的 JS 变体（仅替换 `sendToNative` 的传输层），见 03 章。
- Swift 6 严格并发下把 `WebAppInterface` / 中间件标为 `@MainActor`：`WKWebView` 本就要求主线程访问，用编译器强制替代 Kotlin 的 `Handler` 手工切线程；中间件内部的长任务用 `Task` 包裹。
- 签名与 DID 能力抽象为协议（`WalletSigning` / `DidSDK`），宿主接线：本仓库 `SwiftVault` 提供私钥/秘钥，交易签名由宿主或后续 `SwiftWallet` 模块实现。

## 2. 模块布局（建议）

```text
Sources/SwiftDappConnect/
├── DAppConnectSdk.swift          // 唯一入口：工厂 / JS 加载 / URL 安全 / EIP-6963
├── WebAppInterface.swift         // @MainActor 消息路由（legacy WKScriptMessageHandler + _ccdaoSettle 回传）
├── NativeResponseChannel.swift   // 响应封装：success/error payload 序列化
├── WebOrigin.swift               // origin 归一化 + WALLET_INTERNAL
├── DidDocumentMutationListener.swift
├── middleware/
│   ├── MiddlewareInterfaces.swift
│   ├── EthMiddleware.swift
│   └── SwtcMiddleware.swift
├── provider/
│   ├── Interfaces.swift
│   └── CachingSecretProvider.swift
├── model/
│   ├── DAppMethod.swift
│   └── Models.swift
└── Resources/
    └── ccdao-eip1193-provider-ios.js   // Kotlin JS 的 iOS 传输变体
```

Swift Package 注册示意：

```swift
.target(
    name: "SwiftDappConnect",
    dependencies: [],   // 宿主经协议注入（WalletSigning / DidSDK / Providers），模块不依赖具体钱包实现
    resources: [.copy("Resources")]
)
```

## 3. 类型设计

### 3.1 DAppMethod

```swift
public enum DAppMethod: String {
    case swtcRequestAccounts = "swtc_requestAccounts"
    case swtcSendTransaction = "swtc_sendTransaction"
    case swtcMultiSign = "swtc_multiSign"
    case swtcSignMessage = "swtc_signMessage"
    case swtcGetPublicKey = "swtc_getPublicKey"
    case swtcRequestNfts = "swtc_requestNfts"

    case ethAccounts = "eth_accounts"
    case ethRequestAccounts = "eth_requestAccounts"
    case ethChainId = "eth_chainId"
    case ethBlockNumber = "eth_blockNumber"
    case ethPersonalSign = "personal_sign"
    case ethPersonalEcRecover = "personal_ecRecover"
    case ethSignTypedData = "eth_signTypedData"
    case ethSignTypedDataV3 = "eth_signTypedData_v3"
    case ethSignTypedDataV4 = "eth_signTypedData_v4"
    case ethSendTransaction = "eth_sendTransaction"
    case ethSignTransaction = "eth_signTransaction"
    case ethGetEncryptionPublicKey = "eth_getEncryptionPublicKey"
    case ethDecrypt = "eth_decrypt"
    case ethRequestNfts = "eth_requestNfts"

    case walletSwitchEthereumChain = "wallet_switchEthereumChain"

    case didRequestAccountName = "did_requestAccountName"
    case didGetBase58PublicKey = "did_getBase58PublicKey"
    case didIssueCredential = "did_issueCredential"
    case ipfsPersonalSign = "ipfs_personalSign"
    case ipfsGetPublicKey = "ipfs_getPublicKey"

    case web3ClientVersion = "web3_clientVersion"
    case unknown
}
```

### 3.2 模型与错误

```swift
public enum ChainType: String, CaseIterable, Sendable {
    case eth, bsc, polygon, arb1, base, swtc, moac

    var bip44Code: Int64 { ... }      // 与 Kotlin 一致
    var evmChainId: Int64? { ... }    // eth=1, bsc=56, polygon=137, arb1=42161, base=8453, moac=99
    var isEvm: Bool { self != .swtc }
}

public struct Path: Sendable, Equatable {
    public let chain: Int64
    public let account: Int      // 默认 0，与 Kotlin Path 一致
    public let change: Int
    public let index: Int
    public var isRoot: Bool { account == 0 && change == 0 && index == 0 }

    public init(chain: Int64, account: Int = 0, change: Int = 0, index: Int = 0) { ... }

    /// 对应 Kotlin `Path.root(chainType: ChainType)`：chain = chainType.bip44Code，其余为 0。
    public static func root(chainType: ChainType) -> Path { Path(chain: chainType.bip44Code) }
}

public struct WalletAccount: Sendable, Identifiable, Equatable {
    public let id: String
    public let address: String
    public let chain: ChainType
    public let name: String
    public let isHD: Bool
    public let parentId: String?
    public let path: Path?          // Kotlin 为 Path?，勿压平成 String（否则丢失 isRoot()）
    public let publicKey: String

    // 与 Kotlin core `WalletAccount.isRootHD()` 语义一致：
    // isHD && path?.isRoot() == true && parentId == nil。
    // 注意：DApp 中间件的 HD 根过滤谓词是 `isHD && parentId == nil`（不查 path），
    // 与 isRootHD 不等价，中间件应内联该谓词，勿复用此属性（见 6.2）。
    public var isRootHD: Bool { isHD && path?.isRoot() == true && parentId == nil }
}

public enum DAppConnectError: Error, Equatable {
    case userRejected(String = "User rejected")            // 4001（EIP-1193）
    case chainNotSupported(chainId: Int64)                  // 4902（EIP-3326）
    case unauthorized(String = "Account not authorized")    // 4100：Kotlin 定义了 UnauthorizedException，但路由层从未抛出
    case transaction(message: String, code: Int = -1)       // 通用/交易错误：Kotlin 路由层统一回传 code = -1（非 -32603）
    case methodNotSupported
    case bridgeUnavailable
    case missingParameters(String)
    case internalError(String)

    public var jsonRpcCode: Int { ... }
}
```

### 3.3 消息与响应

```swift
// 注意：params 是异构数组，[Any] 不满足 Decodable，不能靠编译器合成解码；
// 实现时用 JSONSerialization 手写解析，或实现自定义 init(from:)。
public struct DAppRequest {
    public let name: String
    public let network: String
    public let id: String
    public let nonce: String?
    public let params: [Any]?
}

public enum RPCResult {
    case null
    case string(String)
    case number(NSNumber)
    case bool(Bool)
    case object([String: Any])
    case array([Any])

    /// 转成可进 JSONSerialization 的原生值（NSNull/String/NSNumber/Bool/[String:Any]/[Any]）
    var jsonValue: Any {
        switch self {
        case .null: return NSNull()
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o
        case .array(let a): return a
        }
    }
}
```

响应 payload 与 Kotlin `NativeResponseChannel` 完全一致：

```json
{ "nonce": "...", "result": ... }
{ "nonce": "...", "error": { "code": 4001, "message": "..." } }
```

## 4. WebAppInterface（@MainActor 路由）

```swift
@MainActor
public final class WebAppInterface: NSObject, WKScriptMessageHandler {
    private let ethMiddleware: any EthMiddlewareProtocol
    private let swtcMiddleware: any SwtcMiddlewareProtocol
    private let accountProvider: (any AccountProvider)?
    private let secretProvider: (any SecretProvider)?
    private let nftProvider: (any NftProvider)?
    private let didDocumentMutationListener: DidDocumentMutationListener?
    private var chainProvider: (any ChainProvider)?
    private var onAccountSwitched: ((String) -> Void)?

    // H1 修复：origin 不再由宿主全局设置（setOrigin 已废弃为 no-op）。
    // 授权 origin 按消息从 frameInfo.securityOrigin 实时推导，见 userContentController。
    public func setOrigin(_ origin: String) {}

    // Kotlin 的 setChainProvider / setOnAccountSwitched（legacy；链切换主要走 EthMiddleware 构造注入的 chainProvider）：
    public func setChainProvider(_ provider: any ChainProvider) {
        chainProvider = provider
        ethMiddleware.setOnAccountSwitched { [weak self] newAddress in
            self?.onAccountSwitched?(newAddress)
        }
    }

    public func setOnAccountSwitched(_ callback: @escaping (String) -> Void) {
        onAccountSwitched = callback
    }

    // JS 侧：window._tw_.postMessage(json)（legacy handler，无 reply 参数）
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        _ = userContentController

        // best-effort 解析：先取 nonce/id，保证后续失败路径也能带 nonce 回传，
        // JS 的 requestQueue 才能 settle（与 Kotlin 直接丢日志的缺陷区分）。
        // （正文见 WebAppInterface.swift；此处略去 body 解析细节）

        // 安全边界（H1）：origin 一律按消息来源实时推导，绝不使用宿主设置的全局状态。
        // - 只信任主 frame：消息通道对 webview 内所有 frame 开放（forMainFrameOnly
        //   只限制脚本注入），跨域 iframe 的任意 JS 都能 postMessage 到 `_tw_`，
        //   子 frame 消息一律视为伪造并丢弃（JS 侧 60s 超时兜底）。
        // - 主 frame origin 取自 frameInfo.securityOrigin，页面 JS 无法伪造。
        guard
            let origin = WebAppInterface.authorizedOrigin(
                isMainFrame: message.frameInfo.isMainFrame,
                scheme: message.frameInfo.securityOrigin.protocol,
                host: message.frameInfo.securityOrigin.host,
                port: message.frameInfo.securityOrigin.port
            )
        else {
            if message.frameInfo.isMainFrame {
                deliver(NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: "Unsafe or missing origin"))
            }
            return
        }

        // params 是异构数组，用 JSONSerialization 解析（见 3.3，DAppRequest 非 Decodable）
        guard
            let obj,
            let name = obj["name"] as? String,
            let network = obj["network"] as? String,
            let id = obj["id"] as? String
        else {
            deliver(NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: "Malformed request"))
            return
        }
        let request = DAppRequest(
            name: name,
            network: network,
            id: id,
            nonce: obj["nonce"] as? String,
            params: obj["params"] as? [Any]
        )

        Task { @MainActor in
            let payload = await route(request, origin: origin)
            deliver(payload)
        }
    }

    /// Native → JS 响应投递：evaluateJavaScript 调用 provider 的 `window._ccdaoSettle`。
    /// 回传携带 responseToken，provider 闭包校验通过才 settle（M1）。
    private func deliver(_ payload: [String: Any]) {
        guard let webView else { return }
        let nonce = (payload["nonce"] as? String) ?? ""
        let script =
            "window._ccdaoSettle && window._ccdaoSettle(\(Self.jsQuote(nonce)), \(Self.jsQuote(payload.jsonString)), \(Self.jsQuote(self.responseToken)));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
```

> 传输说明：JS→Native 用 legacy `WKScriptMessageHandler`（`window.webkit.messageHandlers._tw_.postMessage(json)` 到达 `userContentController(_:didReceive:)`）；Native→JS 由 `deliver` 经 `evaluateJavaScript` 调用 `window._ccdaoSettle(nonce, payloadJson, token)` 回传（token 鉴权，M1）。路由整体在 `@MainActor` 上执行。所有 handler 与 Kotlin 一样包 try/catch，把异常映射为 RPC 错误码回传。
>
> **回复约定（对 Kotlin 的显式改进）**：所有回复路径（含校验/解析失败）统一带 `nonce` 回传 `{nonce, result|error}` JSON 字符串（经 `_ccdaoSettle` 的 `JSON.parse` 还原）；无法取得 nonce 时（body 非字符串）依赖 JS 侧 `requestQueue` 超时兜底（见 03 章 3.2）。不再像 Kotlin 那样对非法请求只打日志不回复——那样 DApp Promise 会永久挂起。
>
> `.jsonString` 为 `[String: Any]` 的 JSON 序列化辅助，与 `NativeResponseChannel` 的 payload 构造配套：
>
> ```swift
> extension [String: Any] {
>     var jsonString: String {
>         guard
>             let data = try? JSONSerialization.data(withJSONObject: self),
>             let text = String(data: data, encoding: .utf8)
>         else { return "{}" }
>         return text
>     }
> }
> ```
>
> **回复形态（定稿）**：native 统一以 **JSON 字符串** 回传（`_ccdaoSettle(nonce, payloadJson, token)` 内 `JSON.parse`），与 Kotlin wire 格式严格一致，也便于统一日志。不采用 WithReply 的字典直传（该通道在裸测试进程不送达）。

## 5. NativeResponseChannel（Swift）

Kotlin 用 WebMessagePort + `HANDSHAKE`；Swift 用 `evaluateJavaScript` + `window._ccdaoSettle`（带 token）回传，native 侧只负责「构造 payload」：

```swift
enum NativeResponseChannel {
    static func successPayload(nonce: String, result: RPCResult?) -> [String: Any] {
        var payload: [String: Any] = ["nonce": nonce]
        payload["result"] = result?.jsonValue ?? NSNull()
        return payload
    }

    static func errorPayload(nonce: String, code: Int, message: String) -> [String: Any] {
        ["nonce": nonce, "error": ["code": code, "message": message]]
    }
}
```

JS 侧由 `ccdao-eip1193-provider-ios.js` 的 `sendToNative` 携带 reply 回调，把 `{nonce, result|error}` 交给私有 `requestQueue` settle（详见 03 章）。

## 6. 中间件

### 6.1 协议

```swift
public protocol EthMiddlewareProtocol {
    var currentChain: ChainType { get async }
    func setCurrentChain(_ chain: ChainType)
    func setOnAccountSwitched(_ callback: @escaping (String) -> Void)
    func setRequestAccountsCallback(_ callback: RequestAccountsCallback?)

    func requestAccounts(origin: String) async throws -> [String]
    func getChainId() -> String
    func getBlockNumber() async throws -> String
    func personalSign(address: String, message: String, origin: String) async throws -> String
    func recoverPersonalSignature(message: String, signature: String) async throws -> String
    func signTypedData(address: String, typedData: String, version: String, origin: String) async throws -> String
    func getEncryptionPublicKey(address: String, origin: String) async throws -> String
    func decrypt(address: String, encryptedData: String, origin: String) async throws -> String
    func signTransaction(txParams: [String: Any], origin: String) async throws -> SignTransactionResult
    func sendTransaction(txParams: [String: Any], origin: String) async throws -> String
    func switchEthereumChain(chainIdHex: String, origin: String) async throws
}

public protocol SwtcMiddlewareProtocol {
    func setRequestAccountsCallback(_ callback: RequestAccountsCallback?)
    func requestAccounts(origin: String) async throws -> [String]
    func sendTransaction(txParams: [String: Any], origin: String) async throws -> String
    func multiSign(msParams: [String: Any], origin: String) async throws -> [String: Any]
    func signMessage(from: String, data: String, origin: String) async throws -> String
    func getPublicKey(address: String, origin: String) async throws -> String
}

public typealias RequestAccountsCallback = @MainActor (String) async -> Bool
```

### 6.2 实现要点

- `requestAccounts`：无回调直接抛 `.userRejected`；回调拒绝同样抛；账户按当前链/`bip44Code` 过滤，并排除 HD 根——过滤谓词为 `!(account.isHD && account.parentId == nil)`（对应 Kotlin 中间件，**不检查 path，与 `WalletAccount.isRootHD` 不等价**，实现时内联，勿复用该属性）。
- `signTransaction`：补 nonce / EIP-1559 或 legacy gas / gas（估算失败回退 `0x5208`）/ chainId，签名委托 `WalletSigning`。
- `switchEthereumChain`：同链直接返回；`ChainProvider.requestChainSwitch` 确认后切链、选账户（同地址优先）、通知 `onAccountSwitched`。
- 私钥/秘钥获取全部经 `SecretProvider`（可包 `CachingSecretProvider`），origin 透传；SWTC 原生 NFT 路径用 `WebOrigin.walletInternal`。

## 7. Provider 与缓存

```swift
public protocol AccountProvider {
    var accounts: AsyncStream<[WalletAccount]> { get }
    var currentAccount: AsyncStream<WalletAccount?> { get }
    func getAccountsByChain(_ chain: ChainType) -> AsyncStream<[WalletAccount]>
    func getAccountByAddress(_ address: String) async -> WalletAccount?
    func setCurrentAccount(accountId: String) async
    func getAccountName(_ address: String) async -> String?
}

public protocol SecretProvider {
    func getPrivateKeyForAddress(_ address: String, origin: String) async throws -> String?
    func getSecretForAddress(_ address: String, origin: String) async throws -> String?
}
```

`CachingSecretProvider` 用 `actor` 实现：私钥/秘钥各一把锁、缓存键 `pk:|sec: + origin|address`、bridge 窗口 5s、绝对 TTL 20s、`clearCache()` 幂等。

```swift
public actor CachingSecretProvider: SecretProvider {
    private let delegate: any SecretProvider
    private var cache: [String: Entry] = [:]
    private var activeOps = 0
    private var clearTask: Task<Void, Never>?
    // bridgeWindowMs = 5000, maxAgeMs = 20000
}
```

## 8. DAppConnectSdk 入口

```swift
public enum DAppConnectSdk {
    // token 为 WebAppInterface.responseToken（M1/M2）：注入 provider 闭包鉴权 native 回传
    public static func loadProviderJs(token: String) -> String
    public static func loadInitJs(chainIdHex: String, rpcUrl: String, token: String) -> String
    public static func loadAddressJs(address: String, isSwtc: Bool, token: String) -> String
    public static func loadUpdateChainIdJs(chainIdHex: String, rpcUrl: String, token: String) -> String
    public static func loadEip6963IconOverrideJs(iconDataUri: String) -> String
    public static func isSafeUrl(_ url: String) -> Bool
    public static func createEthMiddleware(
        accountProvider: AccountProvider,
        secretProvider: SecretProvider,
        nodeProvider: NodeProvider,
        chainProvider: ChainProvider? = nil,
        initialChain: ChainType = .bsc     // Kotlin 默认 ChainType.BSC
    ) -> EthMiddleware
    public static func createSwtcMiddleware(...) -> SwtcMiddleware
    public static func createWebAppInterface(...) -> WebAppInterface
}
```

- `loadIconAsDataUri`：iOS 无 drawable 资源，宿主直接传 data URI（PNG/SVG）；SDK 内置 SVG「D」盾兜底。
- `isSafeUrl`：与 Kotlin 相同正则（http/https、合法 host、可选端口/路径）。
