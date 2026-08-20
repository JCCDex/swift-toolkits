@testable import SwiftWebviewBridge
import XCTest

/// 真实 WKWebView 集成测试：不注入 FakeRuntime，
/// 走生产路径的 `WebviewBridgeClient()` + 真实 `wallet-bridge.html` JS，
/// 验证 Swift -> JS -> 消息通道 -> Swift 的完整桥接链路。
///
/// 性能说明：iOS 模拟器上每次创建新 client 的首次调用都会冷启动 WebContent
/// 进程并加载 ~6MB vendor JS，本地实测 ~16s，CI（尤其首次冷启动）可能超过 60s。
/// 因此每个用例独立 client（不做跨用例共享，避免 CI 中共享 WebView 状态异常），
/// 且 ready/timeout 都给足余量（120s / 180s）。
@MainActor
final class WebviewBridgeClientBehaviorTests: XCTestCase {

    private static let readyWaitMs: TimeInterval = 120_000
    private static let timeoutMs: TimeInterval = 180_000

    private func makeClient() -> WebviewBridgeClient {
        let client = WebviewBridgeClient()
        client.initialize(config: .bridge(named: "wallet-bridge"))
        return client
    }

    // MARK: - 启动

    func test_start_loadsRealBridge() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        try client.start()

        // 公开行为验证：桥已就绪 → JS 调用能往返并返回真实结果
        let raw = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(raw, "true")
    }

    func test_start_fromBackground_thenCall_resolves() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        // @MainActor 约束：后台线程需经 MainActor.run 切换（对应 Kotlin Handler.post）
        try await MainActor.run { try client.start() }

        let raw = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
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
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
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
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
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
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )

        XCTAssertEqual(raw, "true")
    }

    func test_callJsMethod_coercesBooleanResultToString() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let valid = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(valid, "true")

        let invalid = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": "not a mnemonic"],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(invalid, "false")
    }

    func test_callJsMethod_withEncodableParams_encodesAndExecutes() async throws {
        let client = self.makeClient()
        defer { client.destroy() }

        let raw = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
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
                timeoutMs: Self.timeoutMs,
                readyWaitMs: Self.readyWaitMs
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
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(first, "true")

        client.destroy()

        let second = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )
        XCTAssertEqual(second, "true")
    }
}
