@testable import SwiftWebviewBridge
import XCTest

@MainActor
final class WebviewBridgeClientTests: XCTestCase {
    func test_initialize_setsConfig() {
        let client = WebviewBridgeClient()

        client.initialize(config: WebviewBridgeConfig(bridgeFileName: "custom.html"))

        XCTAssertTrue(client.isInitializedForTest)
        XCTAssertEqual(client.currentConfigForTest.bridgeFileName, "custom.html")
    }

    func test_isInitialized_false_beforeInitialize() {
        XCTAssertFalse(WebviewBridgeClient().isInitializedForTest)
    }

    func test_defaultConfig_usesStableDefaults() {
        let config = WebviewBridgeConfig(bridgeFileName: "wallet-bridge.html")

        XCTAssertEqual(config.bridgeFileName, "wallet-bridge.html")
        XCTAssertEqual(config.jsInterfaceName, "JSBridge")
        XCTAssertEqual(config.consoleTag, "WebViewConsole")
        XCTAssertFalse(config.allowsConsoleForwarding)
    }

    func test_callJsMethod_throwsWhenNotInitialized() async {
        let client = WebviewBridgeClient()

        do {
            _ = try await client.callJsMethod(method: "ping")
            XCTFail("expected notInitialized")
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_callJsMethodAs_throwsWhenNotInitialized() async {
        let client = WebviewBridgeClient()

        do {
            _ = try await client.callJsMethodAs(method: "ping", as: String.self)
            XCTFail("expected notInitialized")
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_start_throwsWhenNotInitialized() {
        XCTAssertThrowsError(try WebviewBridgeClient().start()) { error in
            XCTAssertEqual(error as? WebviewBridgeError, .notInitialized)
        }
    }

    func test_start_throwsWhenBridgeResourceMissing() {
        let client = WebviewBridgeClient()
        client.initialize(config: WebviewBridgeConfig(bridgeFileName: "missing.html"))

        XCTAssertThrowsError(try client.start()) { error in
            XCTAssertEqual(error as? WebviewBridgeError, .missingBridgeResource("missing.html"))
        }
    }

    func test_bridgeReadyScript_usesConfiguredInterfaceName() {
        let client = WebviewBridgeClient()
        client.initialize(config: WebviewBridgeConfig(bridgeFileName: "bridge.html", jsInterfaceName: "BridgeJs"))

        let script = client.bridgeReadyScript()

        XCTAssertTrue(script.contains("BridgeJs.onBridgeReady()"))
    }

    func test_adapterScript_forwardsToMessageHandlers() {
        let script = BridgeScripts.adapter(interfaceName: "BridgeJs")

        XCTAssertTrue(script.contains("window.BridgeJs = {"))
        XCTAssertTrue(script.contains("messageHandlers.onPromiseResult.postMessage"))
        XCTAssertTrue(script.contains("messageHandlers.onBridgeReady.postMessage"))
    }
}
