# 02 · Swift 版设计

## 1. 设计目标与取舍

- 保持 Kotlin 的**行为契约**（就绪、超时、错误、结果字符串化、destroy 重建），把平台相关部分替换为 `WKWebView` 生态。
- iOS 上 JS 桥接没有 `addJavascriptInterface` 的等价物，标准做法是 `WKUserContentController.add(_:name:)` + `WKScriptMessageHandler`；JS 侧需要改为 `window.webkit.messageHandlers.<name>.postMessage(...)`。
- 为了**尽量复用 Kotlin 资产**（vendor 库与 bridge JS 一字不改），在页面加载前注入一个轻量适配脚本，把 `window.JSBridge.onPromiseResult/onBridgeReady` 转发到 WebKit 消息通道。
- Swift 6 严格并发下把 Client 标记为 `@MainActor`：`WKWebView` 本就要求主线程访问，用 `@MainActor` 让编译器强制，替代 Kotlin 的 `Handler.post` 手工切线程。
- 超时不用 `withThrowingTaskGroup` 竞速，而是把「超时定时任务」收进网关的 pending 记录里：注册时启动一个 sleep 任务，结果返回或超时先到先赢，避免 continuation 泄漏。

## 2. 模块布局（建议）

```text
Sources/SwiftWebviewBridge/
├── WebviewBridgeEngine.swift        // 唯一入口（@MainActor 单例）
├── WebviewBridgeClient.swift        // 核心：生命周期 + 调用编排
├── WebviewBridgeConfig.swift        // 配置与 JS 脚本生成
├── WebviewBridgeError.swift         // 错误类型
├── PromiseGateway.swift             // 回调表 / 就绪监听 / 结果解析
├── BridgeMessageHandler.swift       // WKScriptMessageHandler 适配
├── WebViewRuntime.swift             // WKWebView 抽象（可测试性）
└── Resources/
    └── bridge/
        ├── wallet-bridge.html / did-bridge.html
        ├── wallet-bridge.js / did-bridge.js
        └── vendor/*.min.js          // 与 Kotlin assets 相同
```

Swift Package 注册示意：

```swift
.target(
    name: "SwiftWebviewBridge",
    resources: [.copy("Resources/bridge")]
)
```

## 3. 类型设计

### 3.1 ContinuationBox（取消安全工具）

`withCheckedThrowingContinuation` 的续体需要在取消、超时、JS 回调等多个路径中安全恢复，且必须保证恰好一次。把续体装进一个可空盒子，所有路径通过同一个盒子操作：

```swift
/// 线程安全的一次性续体容器。所有路径（结果/超时/取消）通过同一个盒子恢复，
/// 避免重复 resume 和 continuation 泄漏。
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    var continuation: CheckedContinuation<T, Error>?

    func resume(with result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
```

> 在 `@MainActor` 环境下所有操作天然串行，无需额外加锁；`resume` 系列方法恢复后立即置 nil，保证「恰好一次」。标注 `@unchecked Sendable` 以通过 Swift 6 严格并发检查。

`waitForReady` 还需要携带超时任务与监听移除器，用一个专门的 `ReadyWaitBox` 收拢全部可变状态（原因见 3.4 节）：

```swift
/// 就绪等待的一次性状态容器：续体 + 超时任务 + 监听移除器。
/// 所有字段平时只在 @MainActor 上读写；onCancel 通过 cancel() 访问，
/// 靠 @unchecked Sendable 通过编译，靠「先到先赢 + 幂等清理」保证安全。
final class ReadyWaitBox: @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Error>?
    var timeoutTask: Task<Void, Never>?
    var remover: (() -> Void)?

    func resumeIfPending() {
        continuation?.resume()
        continuation = nil
    }

    func resumeIfPending(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    /// 调用方取消：取消超时任务、移除就绪监听、恢复续体（幂等，可重复调用）。
    func cancel() {
        timeoutTask?.cancel()
        remover?()
        resumeIfPending(throwing: CancellationError())
    }
}
```

### 3.2 错误类型

```swift
public enum WebviewBridgeError: Error, Sendable {
    case notInitialized
    case missingBridgeResource(String)
    case invalidParams                  // Encodable 参数编码后不是 JSON 对象
    case timeout
    case jsError(String)                 // 对应 {error: "..."}
    case invalidResponseFormat           // 响应缺 result/error
    case malformedJSON(String)           // 响应不是合法 JSON
    case webViewUnavailable
}
```

### 3.3 配置

```swift
public struct WebviewBridgeConfig {
    public var bridgeFileName: String            // 必填，无默认值（如 "wallet-bridge.html"）
    public var resourceBundle: Bundle            // 默认 .main；SPM 内用 Bundle.module
    public var jsInterfaceName: String           // 默认 "JSBridge"，仅作为 window 对象名
    public var consoleTag: String                // 默认 "WebViewConsole"
    public var allowsConsoleForwarding: Bool     // 默认 false，对应 Kotlin 关闭的 onConsoleMessage

    public init(
        bridgeFileName: String,
        resourceBundle: Bundle = .main,
        jsInterfaceName: String = "JSBridge",
        consoleTag: String = "WebViewConsole",
        allowsConsoleForwarding: Bool = false
    ) {
        self.bridgeFileName = bridgeFileName
        self.resourceBundle = resourceBundle
        self.jsInterfaceName = jsInterfaceName
        self.consoleTag = consoleTag
        self.allowsConsoleForwarding = allowsConsoleForwarding
    }

    public static func bridge(
        named name: String,
        in bundle: Bundle = .main
    ) -> WebviewBridgeConfig {
        WebviewBridgeConfig(bridgeFileName: name + ".html", resourceBundle: bundle)
    }
}
```

说明：Kotlin 的 `bridgeUrl` 直接存 URL 字符串；Swift 改为「文件名 + Bundle」，由 `start()` 解析出文件 URL，兼顾 App target（`Bundle.main`）与 SPM target（`Bundle.module`）。

### 3.4 Promise 网关

回调表、就绪监听、结果解析与 Kotlin 语义一致。因为整体在 `@MainActor` 上运行，`ConcurrentHashMap`/`CopyOnWriteArrayList` 退化为普通字典/字典监听表（`WKScriptMessageHandler` 固定主线程回调，天然串行）。

```swift
@MainActor
final class PromiseGateway {
    struct PendingCall {
        let onResult: (Result<String, Error>) -> Void
        let timeoutTask: Task<Void, Never>
    }

    private var pending: [String: PendingCall] = [:]
    private var readyListeners: [UUID: () -> Void] = [:]
    private(set) var isReady = false

    // MARK: - JS -> Native

    func onPromiseResult(id: String, resultJson: String) {
        finish(id: id, result: Self.parseResult(resultJson))
    }

    func onBridgeReady() {
        isReady = true
        let listeners = readyListeners.values
        readyListeners.removeAll()
        for listener in listeners { listener() }   // 单个监听抛错不阻断其余
    }

    // MARK: - Native -> JS

    /// 注册一次调用：超时任务先到则回 timeout，JS 结果先到则取消超时任务。
    func register(
        id: String,
        timeoutMs: TimeInterval,
        onResult: @escaping (Result<String, Error>) -> Void
    ) {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs * 1_000_000))
            self?.finish(id: id, result: .failure(WebviewBridgeError.timeout))
        }
        pending[id] = PendingCall(onResult: onResult, timeoutTask: timeoutTask)
    }

    /// 移除 pending 并取消超时任务。
    /// 调用方取消 / JS 迟到回调 / destroy 时使用，避免回调/超时任务泄漏。
    func remove(id: String) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeoutTask.cancel()
    }

    // MARK: - 就绪等待

    /// 等待 WebView 就绪，超时抛 `.timeout`。使用 `ReadyWaitBox` +
    /// `withTaskCancellationHandler` 保证所有路径（就绪/超时/取消）都正确清理。
    func waitForReady(timeoutMs: TimeInterval) async throws {
        if isReady { return }

        let box = ReadyWaitBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.continuation = continuation

                box.remover = addReadyListener { [weak box] in
                    box?.timeoutTask?.cancel()
                    box?.resumeIfPending()
                }

                box.timeoutTask = Task { @MainActor [weak box] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs * 1_000_000))
                    box?.remover?()
                    box?.resumeIfPending(throwing: WebviewBridgeError.timeout)
                }

                // 关闭「取消先于 setup」的竞态窗口：setup 后若任务已被取消，立即自清理。
                if Task.isCancelled {
                    box.cancel()
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    func addReadyListener(_ listener: @escaping () -> Void) -> () -> Void {
        if isReady {
            listener()
            return {}
        }
        let token = UUID()
        readyListeners[token] = listener
        return { [weak self] in
            self?.readyListeners.removeValue(forKey: token)
        }
    }

    func resetReady() {
        isReady = false
        readyListeners.removeAll()
    }

    func clearAll() {
        pending.values.forEach { $0.timeoutTask.cancel() }
        pending.removeAll()
        readyListeners.removeAll()
        isReady = false
    }

    // MARK: - 内部

    /// 完成一次调用。结果/超时先到先赢，后到者发现 pending 已移除则 no-op。
    /// 这是 Kotlin `remove(id)?.invoke(resultJson)` 的等价实现。
    private func finish(id: String, result: Result<String, Error>) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeoutTask.cancel()
        call.onResult(result)
    }

    /// 与 Kotlin 相同的解析规则：
    /// - {error} -> jsError
    /// - {result: String} -> 原样
    /// - {result: 数字/布尔/对象} -> JSON 文本（123 -> "123"）
    /// - 缺 result/error -> invalidResponseFormat；非法 JSON -> malformedJSON
    static func parseResult(_ resultJson: String) -> Result<String, Error> {
        guard
            let data = resultJson.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure(WebviewBridgeError.malformedJSON(resultJson))
        }

        if let error = object["error"] as? String {
            return .failure(WebviewBridgeError.jsError(error))
        }
        guard object["result"] != nil else {
            return .failure(WebviewBridgeError.invalidResponseFormat)
        }

        guard let result = object["result"] else {
            return .success("null")
        }
        if let string = result as? String {
            return .success(string)
        }
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let text = String(data: data, encoding: .utf8) {
            return .success(text)
        }
        return .success(String(describing: result))
    }
}
```

### 3.5 WebView 运行时抽象（可测试性）

Kotlin 通过构造函数注入 `webViewFactory` 做单测；Swift 单测无法在无宿主环境下跑 `WKWebView`，所以把 WebView 操作收敛成协议：

```swift
@MainActor
protocol WebViewRuntime: AnyObject {
    var userContentController: WKUserContentController { get }
    var navigationDelegate: WKNavigationDelegate? { get set }
    var isHidden: Bool { get set }

    func loadBridgeFile(_ url: URL, allowingReadAccessTo directory: URL)
    func runJavaScript(_ script: String) async throws -> Any?
    func stopLoading()
    func loadBlank()
    /// 彻底释放 WebView。调用后不应再使用该实例。
    func teardown()
}

@MainActor
extension WKWebView: WebViewRuntime {
    func loadBridgeFile(_ url: URL, allowingReadAccessTo directory: URL) {
        loadFileURL(url, allowingReadAccessTo: directory)
    }

    func runJavaScript(_ script: String) async throws -> Any? {
        try await evaluateJavaScript(script)      // iOS 15+ async 版本
    }

    func loadBlank() {
        load(URLRequest(url: URL(string: "about:blank")!))
    }

    func teardown() {
        stopLoading()
        // 移除所有注入的用户脚本，防止泄漏
        configuration.userContentController.removeAllUserScripts()
        // 移除所有脚本消息处理器（destroy 中已按名移除，此处兜底）
        configuration.userContentController.removeAllScriptMessageHandlers()
    }
}
```

> 协议方法名刻意与 `WKWebView` 现有 API 区分（`runJavaScript` 而非 `evaluateJavaScript`），避免 conformance 内自递归。

### 3.6 WKScriptMessageHandler 适配

```swift
protocol BridgeMessageHandlerDelegate: AnyObject {
    func onPromiseResult(id: String, resultJson: String)
    func onBridgeReady()
    func onConsole(level: String, message: String)
}

@MainActor
final class BridgeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: BridgeMessageHandlerDelegate?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "onPromiseResult":
            guard
                let body = message.body as? [String: Any],
                let id = body["id"] as? String,
                let resultJson = body["resultJson"] as? String
            else { return }
            delegate?.onPromiseResult(id: id, resultJson: resultJson)
        case "onBridgeReady":
            delegate?.onBridgeReady()
        case "onConsole":
            guard
                let body = message.body as? [String: Any],
                let level = body["level"] as? String,
                let messageText = body["message"] as? String
            else { return }
            delegate?.onConsole(level: level, message: messageText)
        default:
            break
        }
    }
}
```

### 3.7 WebviewBridgeClient（核心）

```swift
@MainActor
public final class WebviewBridgeClient: NSObject {
    // 继承 NSObject：WKNavigationDelegate 继承 NSObjectProtocol，
    // 非 NSObject 类无法声明该 conformance（swiftc 实测报错）。
    private let gateway: PromiseGateway
    private let runtimeFactory: (() -> WebViewRuntime)?   // 测试注入点
    private var runtime: WebViewRuntime?
    private var messageHandler: BridgeMessageHandler?
    private var config: WebviewBridgeConfig!   // initialize() 后才有值，读取前有 isInitialized 守卫
    private var resourceBundle: Bundle = .main
    private var isInitialized = false

    public init() {
        gateway = PromiseGateway()
        runtimeFactory = nil
        super.init()
    }

    init(
        gateway: PromiseGateway = PromiseGateway(),
        runtimeFactory: (() -> WebViewRuntime)? = nil
    ) {
        self.gateway = gateway
        self.runtimeFactory = runtimeFactory
        super.init()
    }

    // MARK: - 生命周期

    public func initialize(
        bundle: Bundle = .main,
        config: WebviewBridgeConfig
    ) {
        resourceBundle = bundle
        self.config = config
        isInitialized = true
    }

    public func start() throws {
        guard isInitialized else { throw WebviewBridgeError.notInitialized }
        guard runtime == nil else { return }          // 复用已有 WebView

        gateway.resetReady()

        let webView = makeRuntime()
        guard let bridgeURL = resolveBridgeURL() else {
            throw WebviewBridgeError.missingBridgeResource(config.bridgeFileName)
        }
        webView.loadBridgeFile(bridgeURL, allowingReadAccessTo: bridgeURL.deletingLastPathComponent())
        runtime = webView
    }

    public func destroy() {
        runtime?.stopLoading()
        runtime?.loadBlank()

        if let handler = messageHandler, let runtime {
            runtime.userContentController.removeScriptMessageHandler(forName: "onPromiseResult")
            runtime.userContentController.removeScriptMessageHandler(forName: "onBridgeReady")
            if config.allowsConsoleForwarding {
                runtime.userContentController.removeScriptMessageHandler(forName: "onConsole")
            }
        }
        messageHandler = nil
        runtime?.teardown()
        runtime = nil
        gateway.clearAll()
    }

    // MARK: - 调用 JS

    /// 基础调用：返回 JS 结果的字符串形式。
    /// `onCancel` 通过 `ContinuationBox` 安全恢复续体，避免泄漏。
    public func callJsMethod(
        method: String,
        params: [String: Any]? = nil,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> String {
        guard isInitialized else { throw WebviewBridgeError.notInitialized }
        try startIfNeeded()
        try await gateway.waitForReady(timeoutMs: min(readyWaitMs, timeoutMs))

        let id = UUID().uuidString

        return try await withTaskCancellationHandler {
            let box = ContinuationBox<String>()

            return try await withCheckedThrowingContinuation { continuation in
                box.continuation = continuation

                self.gateway.register(id: id, timeoutMs: timeoutMs) { result in
                    box.resume(with: result)
                }

                guard let runtime = self.runtime else {
                    self.gateway.remove(id: id)
                    box.resume(throwing: WebviewBridgeError.webViewUnavailable)
                    return
                }

                let paramsJs = Self.jsonString(params) ?? "null"
                let script = "PromiseBridge.call(\(Self.jsString(method)), \(paramsJs), \(Self.jsString(id)));"

                Task { @MainActor in
                    do {
                        _ = try await runtime.runJavaScript(script)
                    } catch {
                        self.gateway.remove(id: id)
                        box.resume(throwing: error)
                    }
                }

                // 关闭「取消先于 setup」的竞态窗口：注册完成后若任务已被取消，
                // 立即移除 pending 并恢复续体；onCancel 之后触发时为幂等 no-op。
                if Task.isCancelled {
                    self.gateway.remove(id: id)
                    box.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            // 调用方取消：续体立即恢复（CancellationError），pending 移除投递到主线程。
            // box 已置 nil，即使 JS 迟到响应也只会走到 finish(id) 的 no-op 分支。
            Task { @MainActor [weak self] in
                self?.gateway.remove(id: id)
            }
            box.resume(throwing: CancellationError())
        }
    }

    /// Encodable 参数重载：自动将强类型参数编码为 JSON 字典后调用 JS。
    public func callJsMethod<P: Encodable>(
        method: String,
        params: P,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> String {
        let dict = try Self.jsonDictionary(params)
        return try await callJsMethod(
            method: method,
            params: dict,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    /// 类型化调用：将 JS 返回的 JSON 字符串解码为 Swift 类型。
    public func callJsMethodAs<T: Decodable>(
        method: String,
        params: [String: Any]? = nil,
        as type: T.Type = T.self,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> T {
        let raw = try await callJsMethod(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
        // Kotlin 对 String 目标类型直接返回原文，不经过 Gson
        if T.self == String.self, let string = raw as? T {
            return string
        }
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw WebviewBridgeError.malformedJSON(raw)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Encodable 参数 + Decodable 结果的组合重载。
    public func callJsMethodAs<P: Encodable, T: Decodable>(
        method: String,
        params: P,
        as type: T.Type = T.self,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> T {
        let dict = try Self.jsonDictionary(params)
        return try await callJsMethodAs(
            method: method,
            params: dict,
            as: type,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    // MARK: - 重载解析说明

    // `callJsMethod(method:params:...)` 同时存在 `[String: Any]?` 与 `P: Encodable`
    // 两组重载。字典字面量（如 ["length": 128]）会被编译器解析到非泛型的
    // `[String: Any]?` 重载，无歧义（已用 swiftc 验证）；自定义结构体自动匹配
    // `P: Encodable` 重载。若显式传 `[String: Int]` 变量，需 `as [String: Any]` 转换
    // 或直接使用 Encodable 重载。

    // MARK: - 内部

    private func startIfNeeded() throws {
        if runtime == nil { try start() }
    }

    private func resolveBridgeURL() -> URL? {
        let name = (config.bridgeFileName as NSString).deletingPathExtension
        let ext = (config.bridgeFileName as NSString).pathExtension
        if let url = resourceBundle.url(forResource: name, withExtension: ext) {
            return url
        }
        // SPM `.copy("Resources/bridge")` 会保留子目录结构
        return resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "bridge")
    }

    private func makeRuntime() -> WebViewRuntime {
        if let runtimeFactory {
            return runtimeFactory()
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 对应 Kotlin LOAD_NO_CACHE：不持久化任何 Web 数据。
        // DOM Storage（localStorage/sessionStorage）默认启用，仅在内存中存活。
        configuration.websiteDataStore = .nonPersistent()

        let handler = BridgeMessageHandler()
        handler.delegate = self
        messageHandler = handler

        let controller = configuration.userContentController
        controller.add(handler, name: "onPromiseResult")
        controller.add(handler, name: "onBridgeReady")
        controller.addUserScript(
            WKUserScript(
                source: BridgeScripts.adapter(interfaceName: config.jsInterfaceName),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        if config.allowsConsoleForwarding {
            controller.add(handler, name: "onConsole")
            controller.addUserScript(
                WKUserScript(
                    source: BridgeScripts.consoleForwarding,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.navigationDelegate = self
        return webView
    }

    // MARK: - JSON / JS 字面量工具

    /// Encodable -> JSON 字典。非对象顶层（数组/标量）抛 `.invalidParams`，
    /// 与 Kotlin 只接受 JSONObject 参数的契约保持一致，避免静默变成 nil。
    private static func jsonDictionary<P: Encodable>(_ params: P) throws -> [String: Any]? {
        let data = try JSONEncoder().encode(params)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebviewBridgeError.invalidParams
        }
        return object
    }

    /// [String: Any] -> JSON 文本；nil -> nil（调用处回退 "null"）
    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 生成 JS 字符串字面量（JSON 字符串是 JS 字符串字面量的安全超集），
    /// 等价 Kotlin 的 JSONObject.quote()，避免手拼转义导致注入/语法错误。
    private static func jsString(_ value: String) -> String {
        // 顶层字符串必须加 .fragmentsAllowed：否则 NSJSONSerialization 抛 ObjC 异常，
        // 在 Swift 桥接下会表现为 malloc guard 内存损坏（模拟器实测崩溃）。
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }
}

// MARK: - BridgeMessageHandlerDelegate

extension WebviewBridgeClient: BridgeMessageHandlerDelegate {
    func onPromiseResult(id: String, resultJson: String) {
        gateway.onPromiseResult(id: id, resultJson: resultJson)
    }

    func onBridgeReady() {
        gateway.onBridgeReady()
    }

    func onConsole(level: String, message: String) {
        // 对应 Kotlin 中默认关闭的 onConsoleMessage。
        // 仅在 allowsConsoleForwarding = true 时启用，可用于调试 JS 执行。
        guard config.allowsConsoleForwarding else { return }
        NSLog("[%@] [%@] %@", config.consoleTag, level, message)
    }
}

// MARK: - WKNavigationDelegate

extension WebviewBridgeClient: WKNavigationDelegate {
    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 对应 Kotlin onPageFinished 兜底：did-bridge.js 不主动通知就绪，
        // 在此检测并调用 onBridgeReady()。
        // WKWebView 回调始终在主线程；使用 MainActor.assumeIsolated（Swift 5.9+）
        // 声明进入 @MainActor，避免 non-Sendable WKWebView 的跨 actor 警告。
        MainActor.assumeIsolated {
            let js = "if (window.\(config.jsInterfaceName) && " +
                     "window.\(config.jsInterfaceName).onBridgeReady) {" +
                     "window.\(config.jsInterfaceName).onBridgeReady();}"
            // 使用 completion-handler 版 evaluateJavaScript 避免 async 上下文；
            // 错误静默吞掉，与 Kotlin try-catch 行为一致。
            webView.evaluateJavaScript(js) { _, _ in }
        }
    }

    nonisolated public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // 对应 Kotlin shouldOverrideUrlLoading：只放行本地文件，禁止页面跳转到任意 URL。
        // 新 SDK 中 decisionHandler 为 @MainActor @Sendable，且 navigationAction.request
        // 是 MainActor 隔离属性，需在 assumeIsolated 内访问（swiftc 实测验证）。
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url, url.isFileURL else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
```

### 3.8 WebviewBridgeEngine（唯一入口）

```swift
@MainActor
public final class WebviewBridgeEngine {
    public static let shared = WebviewBridgeEngine()

    private let client: WebviewBridgeClient

    private init() {
        client = WebviewBridgeClient()
    }

    public func initialize(
        bundle: Bundle = .main,
        config: WebviewBridgeConfig
    ) {
        client.initialize(bundle: bundle, config: config)
    }

    public func start() throws {
        try client.start()
    }

    // MARK: 字典参数

    public func callJsMethod(
        method: String,
        params: [String: Any]? = nil,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> String {
        try await client.callJsMethod(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    public func callJsMethodAs<T: Decodable>(
        method: String,
        params: [String: Any]? = nil,
        as type: T.Type = T.self,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> T {
        try await client.callJsMethodAs(
            method: method,
            params: params,
            as: type,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    // MARK: Encodable 参数

    public func callJsMethod<P: Encodable>(
        method: String,
        params: P,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> String {
        try await client.callJsMethod(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    public func callJsMethodAs<P: Encodable, T: Decodable>(
        method: String,
        params: P,
        as type: T.Type = T.self,
        timeoutMs: TimeInterval = 30_000,
        readyWaitMs: TimeInterval = 15_000
    ) async throws -> T {
        try await client.callJsMethodAs(
            method: method,
            params: params,
            as: type,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    public func destroy() {
        client.destroy()
    }
}
```

## 4. JS 适配层与注入顺序

见 [03-protocol-and-js.md](03-protocol-and-js.md)。核心结论：

1. 页面加载前注入 `BridgeScripts.adapter(interfaceName:)`（`atDocumentStart`），把 `window.JSBridge` 的旧接口转发到 `window.webkit.messageHandlers.*`。
2. Kotlin 资产中的 `*-bridge.js` 与 vendor 库无需修改。
3. 就绪通知有两条路径：`wallet-bridge.js` 脚本末尾主动调用；`onPageFinished` 兜底检测（覆盖 `did-bridge.js`）。

## 5. 并发模型小结

| 场景 | Kotlin | Swift |
| --- | --- | --- |
| 主线程约束 | `Handler(Looper.getMainLooper())` 手工投递 | 类标记 `@MainActor`，编译器强制 |
| 异步调用 | `suspend fun` | `async throws` |
| 单次调用等待 | `withTimeout` + `suspendCancellableCoroutine` | `withCheckedThrowingContinuation` + 网关超时任务 |
| 并发调用隔离 | UUID id + `ConcurrentHashMap` | UUID id + `@MainActor` 串行字典 |
| 取消 | `invokeOnCancellation` 移除回调 | `withTaskCancellationHandler` + `ContinuationBox`（恰好一次恢复） |
| 后台线程调用 | 自动切主线程 | 调用方 `await MainActor.run { ... }` 或直接 `Task { @MainActor in }` |

所有取消路径（`callJsMethod` 的 `onCancel`、`waitForReady` 超时/取消）已通过 `ContinuationBox` / `ReadyWaitBox` 正确恢复续体并清理监听器/超时任务；setup 后检查 `Task.isCancelled` 关闭「取消先于 setup」的竞态窗口。详见 [04-migration-and-testing.md](04-migration-and-testing.md) 注意事项第 5 条获取设计演进背景。
