@testable import SwiftWebviewBridge
import XCTest

/// 引擎层测试：同样走真实 WKWebView（不注入 FakeRuntime）。
/// 每个用例独立 engine，超时给足余量（冷启动 + CI 环境）。
@MainActor
final class WebviewBridgeEngineTests: XCTestCase {

    private static let readyWaitMs: TimeInterval = 120_000
    private static let timeoutMs: TimeInterval = 180_000

    private func makeEngine() throws -> WebviewBridgeEngine {
        let engine = WebviewBridgeEngine(bridgeFileName: "wallet-bridge.html")
        try engine.start() // 新语义：start() 内部完成 initialize + 启动 WebView
        return engine
    }

    func test_start_usesConfiguredBridgeFileName() {
        let engine = WebviewBridgeEngine(bridgeFileName: "custom.html")

        // 公开行为验证：start() 会用构造时的 bridgeFileName 找资源，
        // 找不到抛 missingBridgeResource（未初始化时抛的是 notInitialized）。
        XCTAssertThrowsError(try engine.start()) { error in
            XCTAssertEqual(error as? WebviewBridgeError, .missingBridgeResource("custom.html"))
        }
    }

    func test_start_and_destroy_areSafe_afterInitialize() throws {
        let engine = try self.makeEngine()

        try engine.start()
        engine.destroy()
    }

    func test_config_defaults_areStable() {
        let config = WebviewBridgeConfig(bridgeFileName: "wallet-bridge.html")

        XCTAssertEqual(config.bridgeFileName, "wallet-bridge.html")
        XCTAssertEqual(config.jsInterfaceName, "JSBridge")
        XCTAssertEqual(config.consoleTag, "WebViewConsole")
    }

    func test_callMethods_roundTripThroughRealWebView() async throws {
        let engine = try self.makeEngine()
        defer { engine.destroy() }

        let raw = try await engine.call(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(raw, "true")

        let typed: MnemonicResult = try await engine.callAs(
            method: "generateMnemonic",
            params: ["length": 128],
            as: MnemonicResult.self,
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(typed.language, "english")
        XCTAssertEqual(typed.value.split(separator: " ").count, 12)
    }

    func test_callJsMethod_afterDestroy_recreatesRuntimeAndResolves() async throws {
        let engine = try self.makeEngine()
        defer { engine.destroy() }

        let first = try await engine.call(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(first, "true")

        engine.destroy()

        let second = try await engine.call(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(second, "true")
    }

    func test_callJsMethod_throwsWhenNotInitialized() async {
        let engine = WebviewBridgeEngine(bridgeFileName: "wallet-bridge.html")

        do {
            _ = try await engine.call(method: "ping", params: nil)
            XCTFail("expected notInitialized")
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
