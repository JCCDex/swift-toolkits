@testable import SwiftWebviewBridge
import XCTest

private struct DeriveRequest: Encodable {
    let mnemonic: String
    let chain: Int
}

private struct ValueBox: Decodable, Equatable {
    let value: String
}

@MainActor
final class WebviewBridgeClientBehaviorTests: XCTestCase {

    // MARK: - 启动

    func test_start_initializesRuntime_andLoadsBridgeUrl() throws {
        let fake = FakeRuntime()
        var factoryCalls = 0
        let client = WebviewBridgeClient(
            gateway: PromiseGateway(),
            runtimeFactory: {
                factoryCalls += 1
                return fake
            }
        )
        client.initialize(config: .bridge(named: "wallet-bridge"))

        try client.start()

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(fake.loadedURL?.lastPathComponent, "wallet-bridge.html")
        XCTAssertEqual(fake.loadedReadAccessDirectory, fake.loadedURL?.deletingLastPathComponent())
    }

    func test_start_twice_reusesExistingRuntime() throws {
        var factoryCalls = 0
        let client = WebviewBridgeClient(
            gateway: PromiseGateway(),
            runtimeFactory: {
                factoryCalls += 1
                return FakeRuntime()
            }
        )
        client.initialize(config: .bridge(named: "wallet-bridge"))

        try client.start()
        try client.start()

        XCTAssertEqual(factoryCalls, 1)
    }

    func test_start_fromBackground_initializesRuntime() async throws {
        let fake = FakeRuntime()
        let client = WebviewBridgeClient(gateway: PromiseGateway(), runtimeFactory: { fake })
        client.initialize(config: .bridge(named: "wallet-bridge"))

        // @MainActor 约束：后台线程需经 MainActor.run 切换（对应 Kotlin Handler.post）
        try await MainActor.run { try client.start() }

        XCTAssertNotNil(fake.loadedURL)
    }

    // MARK: - 调用与结果

    func test_callJsMethod_returnsResultFromPromiseBridge() async throws {
        let gateway = PromiseGateway()
        let fake = FakeRuntime()
        let client = self.makeClient(gateway: gateway, fake: fake)

        let deferred = Task { () -> String in
            return try await client.callJsMethod(
                method: "generateMnemonic",
                params: ["length": 128],
                timeoutMs: 5000,
                readyWaitMs: 5000
            )
        }

        await Task.yield()
        gateway.onBridgeReady()

        await waitUntil { fake.recordedScripts.contains { $0.contains("PromiseBridge.call") } }
        let script = try XCTUnwrap(fake.recordedScripts.first)
        XCTAssertTrue(script.contains("\"generateMnemonic\""))

        let id = try extractPromiseId(from: script)
        gateway.onPromiseResult(id: id, resultJson: #"{"result":"ok"}"#)

        let value = try await deferred.value
        XCTAssertEqual(value, "ok")
    }

    func test_callJsMethodAs_parsesJsonResult() async throws {
        let gateway = PromiseGateway()
        let fake = FakeRuntime()
        let client = self.makeClient(gateway: gateway, fake: fake)
        try client.start() // 首次调用前显式启动：start() 会 resetReady，再手动标记就绪
        gateway.onBridgeReady()

        let deferred = Task {
            try await client.callJsMethodAs(method: "getValue", as: ValueBox.self, timeoutMs: 5000, readyWaitMs: 5000)
        }

        await waitUntil { fake.recordedScripts.contains { $0.contains("getValue") } }
        let id = try extractPromiseId(from: XCTUnwrap(fake.recordedScripts.last))
        gateway.onPromiseResult(id: id, resultJson: #"{"result":{"value":"alpha"}}"#)

        let value = try await deferred.value
        XCTAssertEqual(value, ValueBox(value: "alpha"))
    }

    func test_callJsMethodAs_returnsRawStringWhenRequested() async throws {
        let gateway = PromiseGateway()
        let fake = FakeRuntime()
        let client = self.makeClient(gateway: gateway, fake: fake)
        try client.start()
        gateway.onBridgeReady()

        let deferred = Task {
            try await client.callJsMethodAs(method: "getValue", as: String.self, timeoutMs: 5000, readyWaitMs: 5000)
        }

        await waitUntil { fake.recordedScripts.count == 1 }
        let id = try extractPromiseId(from: fake.recordedScripts[0])
        gateway.onPromiseResult(id: id, resultJson: #"{"result":"raw-string"}"#)

        let value = try await deferred.value
        XCTAssertEqual(value, "raw-string")
    }

    func test_callJsMethod_coercesNonStringResultToString() async throws {
        let gateway = PromiseGateway()
        let fake = FakeRuntime()
        let client = self.makeClient(gateway: gateway, fake: fake)
        try client.start()
        gateway.onBridgeReady()

        let first = Task {
            try await client.callJsMethod(method: "getNumber", timeoutMs: 5000, readyWaitMs: 5000)
        }
        await waitUntil { fake.recordedScripts.count == 1 }
        let firstId = try extractPromiseId(from: fake.recordedScripts[0])
        gateway.onPromiseResult(id: firstId, resultJson: #"{"result":123}"#)
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, "123")

        let second = Task {
            try await client.callJsMethod(method: "getObject", timeoutMs: 5000, readyWaitMs: 5000)
        }
        await waitUntil { fake.recordedScripts.count == 2 }
        let secondId = try extractPromiseId(from: fake.recordedScripts[1])
        gateway.onPromiseResult(id: secondId, resultJson: #"{"result":{"k":"v"}}"#)
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, #"{"k":"v"}"#)
    }

    func test_callJsMethod_withEncodableParams_encodesDictionary() async throws {
        let gateway = PromiseGateway()
        let fake = FakeRuntime()
        let client = self.makeClient(gateway: gateway, fake: fake)
        try client.start()
        gateway.onBridgeReady()

        let request = DeriveRequest(mnemonic: "word", chain: 60)
        let deferred = Task {
            try await client.callJsMethod(method: "deriveChild", params: request, timeoutMs: 5000, readyWaitMs: 5000)
        }

        await waitUntil { fake.recordedScripts.count == 1 }
        XCTAssertTrue(fake.recordedScripts[0].contains(#""chain":60"#))

        let id = try extractPromiseId(from: fake.recordedScripts[0])
        gateway.onPromiseResult(id: id, resultJson: #"{"result":"ok"}"#)
        let value = try await deferred.value
        XCTAssertEqual(value, "ok")
    }

    func test_callJsMethod_withNonObjectEncodable_throwsInvalidParams() async {
        let client = WebviewBridgeClient()
        client.initialize()

        do {
            _ = try await client.callJsMethod(method: "m", params: [1, 2, 3])
            XCTFail("expected invalidParams")
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, .invalidParams)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - 错误与超时

    func test_callJsMethod_reportsErrorResponse() async throws {
        try await self.assertFailure(
            method: "fail",
            resultJson: #"{"error":"boom"}"#,
            expected: .jsError("boom")
        )
    }

    func test_callJsMethod_reportsInvalidResponseFormat() async throws {
        try await self.assertFailure(
            method: "fail",
            resultJson: #"{"status":"ok"}"#,
            expected: .invalidResponseFormat
        )
    }

    func test_callJsMethod_reportsMalformedJsonResponse() async throws {
        try await self.assertFailure(
            method: "fail",
            resultJson: "not-json",
            expected: .malformedJSON("not-json")
        )
    }

    func test_callJsMethod_timesOutWhenBridgeNeverBecomesReady() async {
        let client = self.makeClient(gateway: PromiseGateway(), fake: FakeRuntime())

        do {
            _ = try await client.callJsMethod(method: "slow", timeoutMs: 200, readyWaitMs: 30)
            XCTFail("expected timeout")
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_callJsMethod_propagatesRuntimeFactoryFailure() async {
        struct FactoryError: Error, LocalizedError {
            var errorDescription: String? {
                "webview-fail"
            }
        }
        let client = WebviewBridgeClient(
            gateway: PromiseGateway(),
            runtimeFactory: { throw FactoryError() }
        )
        client.initialize(config: .bridge(named: "wallet-bridge"))

        do {
            _ = try await client.callJsMethod(method: "ping", timeoutMs: 5000, readyWaitMs: 5000)
            XCTFail("expected factory failure")
        } catch is FactoryError {
            // 符合预期
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - 销毁与重建

    func test_destroy_clearsRuntimeAndGateway() throws {
        let fake = FakeRuntime()
        let gateway = PromiseGateway()
        let client = self.makeClient(gateway: gateway, fake: fake)
        try client.start()
        gateway.onBridgeReady()
        gateway.register(id: "pending", timeoutMs: 60000) { _ in }

        client.destroy()

        XCTAssertEqual(fake.teardownCount, 1)
        XCTAssertEqual(gateway.pendingCount, 0)
        XCTAssertFalse(gateway.isReady)
    }

    func test_callJsMethod_afterDestroy_recreatesRuntimeAndResolves() async throws {
        var factoryCalls = 0
        var fakes: [FakeRuntime] = []
        let gateway = PromiseGateway()
        let client = WebviewBridgeClient(
            gateway: gateway,
            runtimeFactory: {
                factoryCalls += 1
                let fake = FakeRuntime()
                fakes.append(fake)
                return fake
            }
        )
        client.initialize(config: .bridge(named: "wallet-bridge"))
        try client.start()
        gateway.onBridgeReady()

        client.destroy()
        XCTAssertEqual(factoryCalls, 1)

        let deferred = Task {
            try await client.callJsMethod(method: "afterDestroy", timeoutMs: 5000, readyWaitMs: 5000)
        }
        await waitUntil { factoryCalls == 2 }
        gateway.onBridgeReady()
        await waitUntil { fakes[1].recordedScripts.contains { $0.contains("afterDestroy") } }

        let id = try extractPromiseId(from: XCTUnwrap(fakes[1].recordedScripts.last))
        gateway.onPromiseResult(id: id, resultJson: #"{"result":"restarted"}"#)

        let value = try await deferred.value
        XCTAssertEqual(value, "restarted")
    }

    // MARK: - 辅助

    private func makeClient(gateway: PromiseGateway, fake: FakeRuntime) -> WebviewBridgeClient {
        let client = WebviewBridgeClient(gateway: gateway, runtimeFactory: { fake })
        client.initialize(config: .bridge(named: "wallet-bridge"))
        return client
    }

    private func assertFailure(
        method: String,
        resultJson: String,
        expected: WebviewBridgeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let gateway = PromiseGateway()
        let fake = FakeRuntime()
        let client = self.makeClient(gateway: gateway, fake: fake)
        try client.start()
        gateway.onBridgeReady()

        let deferred = Task {
            try await client.callJsMethod(method: method, timeoutMs: 5000, readyWaitMs: 5000)
        }
        await waitUntil { fake.recordedScripts.count == 1 }
        let id = try? extractPromiseId(from: fake.recordedScripts[0])
        if let id {
            gateway.onPromiseResult(id: id, resultJson: resultJson)
        }

        do {
            _ = try await deferred.value
            XCTFail("expected failure", file: file, line: line)
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
