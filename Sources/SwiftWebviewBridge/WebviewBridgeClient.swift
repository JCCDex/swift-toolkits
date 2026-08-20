import Foundation
import WebKit

@MainActor
public final class WebviewBridgeClient: NSObject {
    // 继承 NSObject：WKNavigationDelegate 继承 NSObjectProtocol，
    // 非 NSObject 类无法声明该 conformance。
    let gateway: PromiseGateway
    private let runtimeFactory: (() throws -> WebViewRuntime)?
    private var runtime: WebViewRuntime?
    private var messageHandler: BridgeMessageHandler?
    private var config: WebviewBridgeConfig!
    private var resourceBundle: Bundle = WebviewBridgeResources.bundle
    private var isInitialized = false

    override public init() {
        self.gateway = PromiseGateway()
        self.runtimeFactory = nil
        super.init()
    }

    init(
        gateway: PromiseGateway,
        runtimeFactory: (() throws -> WebViewRuntime)? = nil
    ) {
        self.gateway = gateway
        self.runtimeFactory = runtimeFactory
        super.init()
    }

    // MARK: - 生命周期

    public func initialize(
        bundle: Bundle = WebviewBridgeResources.bundle,
        config: WebviewBridgeConfig
    ) {
        self.resourceBundle = bundle
        self.config = config
        self.isInitialized = true
    }

    public func start() throws {
        guard self.isInitialized else { throw WebviewBridgeError.notInitialized }
        guard self.runtime == nil else { return } // 复用已有 WebView

        self.gateway.resetReady()

        let webView = try makeRuntime()
        guard let bridgeURL = resolveBridgeURL() else {
            throw WebviewBridgeError.missingBridgeResource(self.config.bridgeFileName)
        }
        webView.loadBridgeFile(bridgeURL, allowingReadAccessTo: bridgeURL.deletingLastPathComponent())
        self.runtime = webView
    }

    public func destroy() {
        runtime?.stopLoading()
        runtime?.loadBlank()

        if self.messageHandler != nil, let runtime {
            runtime.userContentController.removeScriptMessageHandler(forName: "onPromiseResult")
            runtime.userContentController.removeScriptMessageHandler(forName: "onBridgeReady")
            if self.config.allowsConsoleForwarding {
                runtime.userContentController.removeScriptMessageHandler(forName: "onConsole")
            }
        }
        self.messageHandler = nil
        runtime?.teardown()
        runtime = nil
        self.gateway.clearAll()
    }

    // MARK: - 调用 JS

    /// 基础调用：返回 JS 结果的字符串形式（与 Kotlin 规则一致）。
    public func callJsMethod(
        method: String,
        params: [String: Any]? = nil,
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
    ) async throws -> String {
        guard self.isInitialized else { throw WebviewBridgeError.notInitialized }
        try self.startIfNeeded()
        try await self.gateway.waitForReady(timeoutMs: min(readyWaitMs, timeoutMs))

        let id = UUID().uuidString
        let box = ContinuationBox<String>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
                // 以 `;null` 结尾（security-review W2）：PromiseBridge.call 是 async 函数、返回 Promise，
                // evaluateJavaScript 无法序列化会报 "unsupported type"；结果本就经 onPromiseResult 回调
                // 返回，evaluateJavaScript 的返回值弃用，故用尾随 null 使其可序列化。
                let script = "PromiseBridge.call(\(Self.jsString(method)), \(paramsJs), \(Self.jsString(id)));null"

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
    public func callJsMethod(
        method: String,
        params: some Encodable,
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
    ) async throws -> String {
        let dict = try Self.jsonDictionary(params)
        return try await self.callJsMethod(
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
        as _: T.Type = T.self,
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
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
    public func callJsMethodAs<T: Decodable>(
        method: String,
        params: some Encodable,
        as type: T.Type = T.self,
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
    ) async throws -> T {
        let dict = try Self.jsonDictionary(params)
        return try await self.callJsMethodAs(
            method: method,
            params: dict,
            as: type,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    // MARK: - 内部

    private func startIfNeeded() throws {
        if self.runtime == nil {
            try self.start()
        }
    }

    private func resolveBridgeURL() -> URL? {
        let name = (config.bridgeFileName as NSString).deletingPathExtension
        let ext = (config.bridgeFileName as NSString).pathExtension
        if let url = resourceBundle.url(forResource: name, withExtension: ext) {
            return url
        }
        // SPM `.copy("Resources/bridge")` 会保留子目录结构
        return self.resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "bridge")
    }

    private func makeRuntime() throws -> WebViewRuntime {
        if let runtimeFactory {
            return try runtimeFactory()
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 对应 Kotlin LOAD_NO_CACHE：不持久化任何 Web 数据。
        // DOM Storage（localStorage/sessionStorage）默认启用，仅在内存中存活。
        configuration.websiteDataStore = .nonPersistent()

        let handler = BridgeMessageHandler()
        handler.delegate = self
        self.messageHandler = handler

        let controller = configuration.userContentController
        controller.add(handler, name: "onPromiseResult")
        controller.add(handler, name: "onBridgeReady")
        controller.addUserScript(
            WKUserScript(
                source: BridgeScripts.adapter(interfaceName: self.config.jsInterfaceName),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        if self.config.allowsConsoleForwarding {
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

    /// 对应 Kotlin onPageFinished 的就绪兜底脚本（did-bridge.js 不主动通知就绪）。
    func bridgeReadyScript() -> String {
        "if (window.\(self.config.jsInterfaceName) && " +
            "window.\(self.config.jsInterfaceName).onBridgeReady) {" +
            "window.\(self.config.jsInterfaceName).onBridgeReady();}"
    }

    // MARK: - JSON / JS 字面量工具

    /// Encodable -> JSON 字典。非对象顶层（数组/标量）抛 `.invalidParams`，
    /// 与 Kotlin 只接受 JSONObject 参数的契约保持一致，避免静默变成 nil。
    private static func jsonDictionary(_ params: some Encodable) throws -> [String: Any] {
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
        // 顶层字符串必须加 .fragmentsAllowed，否则 NSJSONSerialization 抛 ObjC 异常，
        // 在 Swift 桥接下表现为内存损坏（malloc guard 报错）。
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }
}

// MARK: - BridgeMessageHandlerDelegate

extension WebviewBridgeClient: BridgeMessageHandlerDelegate {
    func onPromiseResult(id: String, resultJson: String) {
        self.gateway.onPromiseResult(id: id, resultJson: resultJson)
    }

    func onBridgeReady() {
        self.gateway.onBridgeReady()
    }

    func onConsole(level: String, message: String) {
        // 对应 Kotlin 中默认关闭的 onConsoleMessage。
        // 仅在 allowsConsoleForwarding = true 时启用，可用于调试 JS 执行。
        guard self.config.allowsConsoleForwarding else { return }
        NSLog("[%@] [%@] %@", self.config.consoleTag, level, message)
    }
}

// MARK: - WKNavigationDelegate

extension WebviewBridgeClient: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        // 对应 Kotlin onPageFinished 兜底：did-bridge.js 不主动通知就绪，
        // 在此检测并调用 onBridgeReady()。
        // WKWebView 回调始终在主线程；使用 MainActor.assumeIsolated（Swift 5.9+）
        // 声明进入 @MainActor，避免 non-Sendable WKWebView 的跨 actor 警告。
        MainActor.assumeIsolated {
            // 使用 completion-handler 版 evaluateJavaScript 避免 async 上下文；
            // 错误静默吞掉，与 Kotlin try-catch 行为一致。
            webView.evaluateJavaScript(self.bridgeReadyScript()) { _, _ in }
        }
    }

    public nonisolated func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // 对应 Kotlin shouldOverrideUrlLoading：只放行本地文件，禁止页面跳转到任意 URL。
        // 新 SDK 中 decisionHandler 为 @MainActor @Sendable，且 navigationAction.request
        // 是 MainActor 隔离属性，需在 assumeIsolated 内访问。
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url, url.isFileURL else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
