@testable import SwiftWebviewBridge
import XCTest

/// 引擎层测试：同样走真实 WKWebView（不注入 FakeRuntime）。
/// 与客户端行为测试一样，普通往返用例共享一个 engine，只付一次冷启动；
/// 销毁/重建用例使用独立 engine。
@MainActor
final class WebviewBridgeEngineTests: XCTestCase {

    private static let readyWaitMs: TimeInterval = 60000
    private static let timeoutMs: TimeInterval = 90000

    /// 共享 engine：整个测试类只冷启动一次。
    private static let sharedEngine: WebviewBridgeEngine = {
        let engine = WebviewBridgeEngine(client: WebviewBridgeClient())
        engine.initialize(config: .bridge(named: "wallet-bridge"))
        return engine
    }()

    private func makeStandaloneEngine() -> WebviewBridgeEngine {
        let engine = WebviewBridgeEngine(client: WebviewBridgeClient())
        engine.initialize(config: .bridge(named: "wallet-bridge"))
        return engine
    }

    func test_initialize_setsConfig() {
        let engine = WebviewBridgeEngine(client: WebviewBridgeClient())

        engine.initialize(config: WebviewBridgeConfig(bridgeFileName: "custom.html"))

        XCTAssertTrue(engine.isInitializedForTest)
        XCTAssertEqual(engine.currentConfigForTest.bridgeFileName, "custom.html")
    }

    func test_start_and_destroy_areSafe_afterInitialize() throws {
        let engine = self.makeStandaloneEngine()

        try engine.start()
        engine.destroy()

        XCTAssertTrue(engine.isInitializedForTest)
    }

    func test_config_defaults_areStable() {
        let config = WebviewBridgeConfig()

        XCTAssertEqual(config.bridgeFileName, "bridge.html")
        XCTAssertEqual(config.jsInterfaceName, "JSBridge")
        XCTAssertEqual(config.consoleTag, "WebViewConsole")
    }

    func test_callMethods_roundTripThroughRealWebView() async throws {
        let engine = Self.sharedEngine

        let raw = try await engine.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(raw, "true")

        let typed: MnemonicResult = try await engine.callJsMethodAs(
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
        let engine = self.makeStandaloneEngine()
        defer { engine.destroy() }

        let first = try await engine.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(first, "true")

        engine.destroy()

        let second = try await engine.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(second, "true")
    }

    func test_callJsMethod_throwsWhenNotInitialized() async {
        let engine = WebviewBridgeEngine(client: WebviewBridgeClient())

        do {
            _ = try await engine.callJsMethod(method: "ping")
            XCTFail("expected notInitialized")
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
