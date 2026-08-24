import Foundation

/// 隐藏 WebView 桥的统一抽象：SwiftWallet（`wallet-bridge.html`）与 SwiftDid
/// （`did-bridge.html`）共用的桥协议——start/destroy 生命周期 + JSON-RPC 式
/// `call`/`callTyped`（便捷版与显式超时版重载）。宿主/测试可注入自定义实现
/// （对应 Kotlin `installBridgeForTest`）。
@MainActor
public protocol EngineBridge: AnyObject {
    /// 初始化并启动隐藏 WebView（加载 bridge 文件）。
    func start() throws
    /// 销毁桥持有的隐藏 WebView（只销毁自己的 runtime，不影响其它桥实例）。
    func destroy()
    /// 调用桥 JS 方法，返回原始字符串结果（便捷版：使用默认超时）。
    func call(method: String, params: [String: Any]?) async throws -> String
    /// 调用桥 JS 方法，返回原始字符串结果（显式超时版）。
    func call(method: String, params: [String: Any]?, timeoutMs: TimeInterval, readyWaitMs: TimeInterval) async throws -> String
    /// 调用桥 JS 方法，并把返回的 JSON 解码为 `T`（便捷版：使用默认超时）。
    func callTyped<T: Decodable>(method: String, params: [String: Any]?, asType: T.Type) async throws -> T
    /// 调用桥 JS 方法，并把返回的 JSON 解码为 `T`（显式超时版）。
    func callTyped<T: Decodable>(method: String, params: [String: Any]?, asType: T.Type, timeoutMs: TimeInterval, readyWaitMs: TimeInterval) async throws -> T
}

/// 隐藏 WebView 引擎/桥（SwiftWebviewBridge，合并自原 `WebViewBridgeEngine` 与
/// `EngineBridge`，实现以 EngineBridge 为主）：按 `bridgeFileName` 参数化，包装一个
/// `WebViewBridgeClient`（隐藏 WKWebView + 桥接 JS），遵循 `EngineBridge` 协议。
///
/// SwiftWallet（`wallet-bridge.html`）与 SwiftDid（`did-bridge.html`）共用同一实现，
/// 各开独立 WebView、互不影响。需要加载不同 bridge 文件时分别新建实例：
/// `WebViewBridgeEngine(bridgeFileName: "wallet-bridge.html")` /
/// `WebViewBridgeEngine(bridgeFileName: "did-bridge.html")`。
@MainActor
public final class WebViewBridgeEngine: EngineBridge {
    private let client: WebViewBridgeClient
    private let bridgeFileName: String

    /// - Parameters:
    ///   - bridgeFileName: 桥 HTML 文件名（如 `"wallet-bridge.html"` / `"did-bridge.html"`），
    ///     经 `WebViewBridgeConfig` 在默认 bundle 中定位资源。
    ///   - client: 底层隐藏 WebView 客户端；默认新建（也可注入 FakeRuntime 做测试）。
    public init(
        bridgeFileName: String,
        client: WebViewBridgeClient = WebViewBridgeClient()
    ) {
        self.bridgeFileName = bridgeFileName
        self.client = client
    }

    /// 初始化配置（幂等覆盖）并启动隐藏 WebView（加载 bridge 文件）。
    /// 未调用前其它方法抛 `notInitialized`。
    public func start() throws {
        self.client.initialize(
            bundle: WebViewBridgeResources.bundle,
            config: WebViewBridgeConfig(bridgeFileName: self.bridgeFileName)
        )
        try self.client.start()
    }

    /// 销毁持有的隐藏 WebView（只销毁本实例的 client，不影响其它桥实例）。
    public func destroy() {
        self.client.destroy()
    }

    // MARK: - EngineBridge：call / callTyped

    public func call(method: String, params: [String: Any]?) async throws -> String {
        try await self.call(method: method, params: params, timeoutMs: 30000, readyWaitMs: 15000)
    }

    public func call(
        method: String,
        params: [String: Any]?,
        timeoutMs: TimeInterval,
        readyWaitMs: TimeInterval
    ) async throws -> String {
        try await self.client.callJSMethod(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    public func callTyped<T: Decodable>(method: String, params: [String: Any]?, asType: T.Type) async throws -> T {
        try await self.callTyped(method: method, params: params, asType: asType, timeoutMs: 30000, readyWaitMs: 15000)
    }

    public func callTyped<T: Decodable>(
        method: String,
        params: [String: Any]?,
        asType: T.Type,
        timeoutMs: TimeInterval,
        readyWaitMs: TimeInterval
    ) async throws -> T {
        try await self.client.callJSMethodAs(
            method: method,
            params: params,
            as: asType,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }
}
