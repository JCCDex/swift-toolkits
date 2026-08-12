@testable import SwiftWebviewBridge
import XCTest

/// 真实 WKWebView 集成测试：不注入 FakeRuntime，
/// 走生产路径的 `WebviewBridgeClient()` + 真实 `wallet-bridge.html` JS，
/// 验证 Swift -> JS -> 消息通道 -> Swift 的完整桥接链路。
///
/// 性能说明：iOS 模拟器上首次调用会冷启动 WebContent 进程并加载 ~6MB vendor JS，
/// 实测可达 16s+（CI 上更慢）。因此：
/// - 普通往返用例共享一个 client，整个测试类只冷启动一次；
/// - ready/timeout 都留足余量（60s / 90s）；
/// - 涉及「启动流程 / 销毁重建」的用例使用独立 client，避免共享状态干扰。
@MainActor
final class WebviewBridgeClientBehaviorTests: XCTestCase {

    private static let readyWaitMs: TimeInterval = 60000
    private static let timeoutMs: TimeInterval = 90000

    /// 共享 client：首个用例触发冷启动，后续用例直接复用热 WebView。
    private static let sharedClient: WebviewBridgeClient = {
        let client = WebviewBridgeClient()
        client.initialize(config: .bridge(named: "wallet-bridge"))
        return client
    }()

    /// 独立 client：用于「启动流程 / 销毁重建」这类必须独占实例的用例。
    private func makeStandaloneClient() -> WebviewBridgeClient {
        let client = WebviewBridgeClient()
        client.initialize(config: .bridge(named: "wallet-bridge"))
        return client
    }

    // MARK: - 启动（独立 client）

    func test_start_loadsRealBridge() throws {
        let client = self.makeStandaloneClient()
        defer { client.destroy() }

        try client.start()

        XCTAssertTrue(client.isInitializedForTest)
    }

    func test_start_fromBackground_thenCall_resolves() async throws {
        let client = self.makeStandaloneClient()
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

    // MARK: - 真实 JS 往返（共享 client）

    func test_callJsMethod_generateMnemonic_returnsRealResult() async throws {
        let client = Self.sharedClient

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
        let client = Self.sharedClient

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
        let client = Self.sharedClient

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
        let client = Self.sharedClient

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
        let client = Self.sharedClient

        let raw = try await client.callJsMethod(
            method: "validateMnemonic",
            params: ["mnemonic": validBip39Mnemonic],
            timeoutMs: Self.timeoutMs,
            readyWaitMs: Self.readyWaitMs
        )

        XCTAssertEqual(raw, "true")
    }

    // MARK: - 错误路径（共享 client）

    func test_callJsMethod_unknownMethod_reportsJsError() async throws {
        let client = Self.sharedClient

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

    // MARK: - 销毁与重建（独立 client）

    func test_destroy_thenCall_recreatesRealWebViewAndResolves() async throws {
        let client = self.makeStandaloneClient()
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
