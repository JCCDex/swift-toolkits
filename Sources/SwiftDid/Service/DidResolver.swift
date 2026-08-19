import Foundation

/// 链上解析抽象（对应 Kotlin `IDidResolver`，见 Did-Swift 02 §3）。
/// 自由线程（不加 @MainActor）；默认实现 `BridgeDidResolver` 经 @MainActor 桥时异步 hop 到主 actor。
public protocol DidResolver: AnyObject, Sendable {
    func resolve(_ did: String) async throws -> String
}

/// 默认实现：桥调 `didResolve`（`"null"` / `"{}"` / 空串由调用方判 missing）。
public final class BridgeDidResolver: DidResolver, @unchecked Sendable {
    private let bridge: any DidBridge

    public init(bridge: any DidBridge) {
        self.bridge = bridge
    }

    public func resolve(_ did: String) async throws -> String {
        try await self.bridge.call(method: "didResolve", params: ["did": did])
    }
}
