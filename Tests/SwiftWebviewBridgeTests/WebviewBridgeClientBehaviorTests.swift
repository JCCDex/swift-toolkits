@testable import SwiftWebviewBridge
import XCTest

/// 真实 WKWebView 集成测试：不注入 FakeRuntime，
/// 走生产路径的 `WebviewBridgeClient()` + 真实 `wallet-bridge.html` JS，
/// 验证 Swift -> JS -> 消息通道 -> Swift 的完整桥接链路。
@MainActor
final class WebviewBridgeClientBehaviorTests: XCTestCase {

    private func makeClient() -> WebviewBridgeClient {
        let client = WebviewBridgeClient()
        client.initialize(config: .bridge(named: "wallet-bridge"))
        return client
    }

    // MARK: - 启动

    func test_start_loadsRealBridge() throws {
        let client = self.makeClient()
        defer { client.destroy() }

        try client.start()

        XCTAssertTrue(client.isInitializedForTest)
    }

    func test_start_fromBackground_thenCall_resolves() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        // @MainActor 约束：后台线程需经 MainActor.run 切换（对应 Kotlin Handler.post）
        try await MainActor.run { try client.start() }

        let raw = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: 15000,
            readyWaitMs: 10000
        )
        XCTAssertEqual(raw, "true")
    }

    // MARK: - 真实 JS 往返

    func test_callJsMethod_generateMnemonic_returnsRealResult() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let raw = try await client.callJsMethod(
            method: "generateMnemonic",
            params: ["length": 128],
            timeoutMs: 15000,
            readyWaitMs: 10000
        )

        let data = try XCTUnwrap(raw.data(using: .utf8))
        let result = try JSONDecoder().decode(MnemonicResult.self, from: data)
        XCTAssertEqual(result.language, "english")
        XCTAssertEqual(result.value.split(separator: " ").count, 12) // 128-bit -> 12 words
    }

    func test_callJsMethodAs_decodesTypedResult() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let result: MnemonicResult = try await client.callJsMethodAs(
            method: "generateMnemonic",
            params: ["length": 128],
            as: MnemonicResult.self,
            timeoutMs: 15000,
            readyWaitMs: 10000
        )

        XCTAssertEqual(result.language, "english")
        XCTAssertEqual(result.value.split(separator: " ").count, 12)
    }

    func test_callJsMethodAs_stringTarget_returnsRawString() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let raw = try await client.callJsMethodAs(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            as: String.self,
            timeoutMs: 15000,
            readyWaitMs: 10000
        )

        XCTAssertEqual(raw, "true")
    }

    func test_callJsMethod_coercesBooleanResultToString() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let valid = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: 15000,
            readyWaitMs: 10000
        )
        XCTAssertEqual(valid, "true")

        let invalid = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": "not a mnemonic"],
            timeoutMs: 15000,
            readyWaitMs: 10000
        )
        XCTAssertEqual(invalid, "false")
    }

    func test_callJsMethod_withEncodableParams_encodesAndExecutes() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let raw = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: 15000,
            readyWaitMs: 10000
        )

        XCTAssertEqual(raw, "true")
    }

    // MARK: - 错误路径

    func test_callJsMethod_unknownMethod_reportsJsError() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        do {
            _ = try await client.callJsMethod(
                method: "noSuchMethod",
                timeoutMs: 15000,
                readyWaitMs: 10000
            )
            XCTFail("expected jsError")
        } catch let error as WebviewBridgeError {
            XCTAssertEqual(error, .jsError("no such method: noSuchMethod"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - 销毁与重建

    func test_destroy_thenCall_recreatesRealWebViewAndResolves() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let first = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: 15000,
            readyWaitMs: 10000
        )
        XCTAssertEqual(first, "true")

        client.destroy()

        let second = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: 15000,
            readyWaitMs: 10000
        )
        XCTAssertEqual(second, "true")
    }
}
