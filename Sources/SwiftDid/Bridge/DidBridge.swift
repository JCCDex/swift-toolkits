import Foundation
import SwiftWebviewBridge

/// 桥抽象（对应 Kotlin `IDidBridge`，见 Did-Swift 02 §3）：可注入 Fake 测试。
@MainActor
public protocol DidBridge: AnyObject {
    func call(method: String, params: [String: Any]?) async throws -> String
    func callAs<T: Decodable>(method: String, params: [String: Any]?, as type: T.Type) async throws -> T
    /// 销毁桥持有的隐藏 WebView（只销毁自己的 runtime，不影响 SwiftWallet 的共享引擎）。
    func destroy()
}

/// 真实桥：自持 `WebviewBridgeClient` 加载 `did-bridge.html`（对齐 Kotlin `AndroidDidWebRuntime` 的独立 WebView；
/// **不复用 `WebviewBridgeEngine.shared`**——单例已被 SwiftWallet 的 wallet-bridge 占用）。
///
/// 网关策略：`did-bridge.js` 的 IPFS 网关**保持硬编码**（`https://wodecards.wh.jccdex.cn:8550`），
/// 不做注入（见 Did-Swift 03 §3；security-review D5 为已知接受项）。加载直接用 SwiftWebviewBridge
/// 默认 bundle（`resolveBridgeURL` 自动落到 `bridge/` 子目录），无需临时 bundle。
@MainActor
public final class EngineDidBridge: DidBridge {
    private let client: WebviewBridgeClient

    public init(client: WebviewBridgeClient = WebviewBridgeClient()) {
        self.client = client
    }

    public func start() throws {
        let bundle = WebviewBridgeResources.bundle
        self.client.initialize(
            bundle: bundle,
            config: WebviewBridgeConfig(bridgeFileName: "did-bridge.html", resourceBundle: bundle)
        )
        try self.client.start()
    }

    public func destroy() {
        self.client.destroy()
    }

    public func call(method: String, params: [String: Any]?) async throws -> String {
        try await self.client.callJsMethod(method: method, params: params)
    }

    public func callAs<T: Decodable>(method: String, params: [String: Any]?, as type: T.Type) async throws -> T {
        try await self.client.callJsMethodAs(method: method, params: params, as: type)
    }
}
