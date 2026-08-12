@testable import SwiftWebviewBridge
import XCTest

@MainActor
final class WebviewBridgeEngineTests: XCTestCase {
    func test_initialize_setsConfig() {
        let engine = WebviewBridgeEngine(client: WebviewBridgeClient())

        engine.initialize(config: WebviewBridgeConfig(bridgeFileName: "custom.html"))

        XCTAssertTrue(engine.isInitializedForTest)
        XCTAssertEqual(engine.currentConfigForTest.bridgeFileName, "custom.html")
    }

    func test_start_and_destroy_areSafe_afterInitialize() throws {
        let fake = FakeRuntime()
        let engine = WebviewBridgeEngine(
            client: WebviewBridgeClient(gateway: PromiseGateway(), runtimeFactory: { fake })
        )

        engine.initialize(config: .bridge(named: "wallet-bridge"))
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

    func test_callMethods_delegateToClient() async throws {
        let gateway = PromiseGateway()
        let fake = FakeRuntime()
        let engine = WebviewBridgeEngine(
            client: WebviewBridgeClient(gateway: gateway, runtimeFactory: { fake })
        )
        engine.initialize(config: .bridge(named: "wallet-bridge"))
        try engine.start()
        gateway.onBridgeReady()

        let first = Task {
            try await engine.callJsMethod(
                method: "generateMnemonic",
                params: ["length": 128],
                timeoutMs: 5000,
                readyWaitMs: 5000
            )
        }
        await waitUntil { fake.recordedScripts.count == 1 }
        let firstId = try extractPromiseId(from: fake.recordedScripts[0])
        gateway.onPromiseResult(id: firstId, resultJson: #"{"result":"ok"}"#)
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, "ok")

        let second = Task {
            try await engine.callJsMethodAs(method: "getValue", as: String.self, timeoutMs: 5000, readyWaitMs: 5000)
        }
        await waitUntil { fake.recordedScripts.count == 2 }
        let secondId = try extractPromiseId(from: fake.recordedScripts[1])
        gateway.onPromiseResult(id: secondId, resultJson: #"{"result":"raw"}"#)
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, "raw")
    }

    func test_callJsMethod_afterDestroy_recreatesRuntimeAndResolves() async throws {
        var factoryCalls = 0
        var fakes: [FakeRuntime] = []
        let gateway = PromiseGateway()
        let engine = WebviewBridgeEngine(
            client: WebviewBridgeClient(
                gateway: gateway,
                runtimeFactory: {
                    factoryCalls += 1
                    let fake = FakeRuntime()
                    fakes.append(fake)
                    return fake
                }
            )
        )
        engine.initialize(config: .bridge(named: "wallet-bridge"))
        try engine.start()
        gateway.onBridgeReady()

        engine.destroy()
        XCTAssertEqual(factoryCalls, 1)

        let deferred = Task {
            try await engine.callJsMethod(method: "afterDestroy", timeoutMs: 5000, readyWaitMs: 5000)
        }
        await waitUntil { factoryCalls == 2 }
        gateway.onBridgeReady()
        await waitUntil { fakes[1].recordedScripts.contains { $0.contains("afterDestroy") } }

        let id = try extractPromiseId(from: XCTUnwrap(fakes[1].recordedScripts.last))
        gateway.onPromiseResult(id: id, resultJson: #"{"result":"restarted"}"#)

        let value = try await deferred.value
        XCTAssertEqual(value, "restarted")
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
