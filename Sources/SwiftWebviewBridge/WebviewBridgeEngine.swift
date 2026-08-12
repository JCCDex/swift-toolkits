import Foundation

@MainActor
public final class WebviewBridgeEngine {
    public static let shared = WebviewBridgeEngine()

    private let client: WebviewBridgeClient

    private init() {
        self.client = WebviewBridgeClient()
    }

    /// 测试注入：用自定义 client（FakeRuntime）构造引擎。
    init(client: WebviewBridgeClient) {
        self.client = client
    }

    public func initialize(
        bundle: Bundle = WebviewBridgeResources.bundle,
        config: WebviewBridgeConfig = WebviewBridgeConfig()
    ) {
        self.client.initialize(bundle: bundle, config: config)
    }

    public func start() throws {
        try self.client.start()
    }

    // MARK: - 字典参数

    public func callJsMethod(
        method: String,
        params: [String: Any]? = nil,
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
    ) async throws -> String {
        try await self.client.callJsMethod(
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
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
    ) async throws -> T {
        try await self.client.callJsMethodAs(
            method: method,
            params: params,
            as: type,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    // MARK: - Encodable 参数

    public func callJsMethod(
        method: String,
        params: some Encodable,
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
    ) async throws -> String {
        try await self.client.callJsMethod(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    public func callJsMethodAs<T: Decodable>(
        method: String,
        params: some Encodable,
        as type: T.Type = T.self,
        timeoutMs: TimeInterval = 30000,
        readyWaitMs: TimeInterval = 15000
    ) async throws -> T {
        try await self.client.callJsMethodAs(
            method: method,
            params: params,
            as: type,
            timeoutMs: timeoutMs,
            readyWaitMs: readyWaitMs
        )
    }

    public func destroy() {
        self.client.destroy()
    }

    /// 对应 Kotlin internal 测试钩子
    var isInitializedForTest: Bool {
        self.client.isInitializedForTest
    }

    var currentConfigForTest: WebviewBridgeConfig {
        self.client.currentConfigForTest
    }
}
