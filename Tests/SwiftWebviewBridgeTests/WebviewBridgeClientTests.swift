@testable import SwiftWebviewBridge
import WebKit
import XCTest

@MainActor
final class WebviewBridgeClientTests: XCTestCase {
    func test_initialize_setsConfig() {
        let client = WebviewBridgeClient()

        client.initialize(config: WebviewBridgeConfig(bridgeFileName: "custom.html"))

        // 公开行为验证：初始化后 start() 会用所配置的 bridgeFileName 找资源，
        // 找不到抛 missingBridgeResource（未初始化时抛的是 notInitialized）。
        XCTAssertThrowsError(try client.start()) { error in
            XCTAssertEqual(error as? WebviewBridgeError, .missingBridgeResource("custom.html"))
        }
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

    // MARK: - P0-2：跨线程取消 / 并发 resume 恰好一次

    func test_continuationBox_concurrentResume_resumesExactlyOnce() async {
        // 确定性回归：两个线程并发 resume 同一续体（模拟主线程 JS 结果 + 取消线程 onCancel
        // 同时命中）。修复前无锁，两个线程都读到非 nil 续体 → double-resume 运行时崩溃；
        // 修复后 take() 原子取走，先到先赢、后到者 no-op。
        let box = ContinuationBox<String>()
        let task = Task { () -> String in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                box.install(continuation)
            }
        }
        while !box.isInstalled {
            await Task.yield()
        }

        // 并发两路 resume（模拟主线程 JS 结果 + 取消线程 onCancel 同时命中）
        let resumeA = Task.detached { box.resume(throwing: CancellationError()) }
        let resumeB = Task.detached { box.resume(with: .success("late")) }
        _ = await resumeA.value
        _ = await resumeB.value

        do {
            let value = try await task.value
            XCTAssertEqual(value, "late", "成功路径先到 → 返回结果")
        } catch is CancellationError {
            // 取消路径先到也合法：两种结果都算恰好一次 resume
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_callJsMethod_cancelledFromBackgroundThread_resumesExactlyOnce() async throws {
        // P0-2 回归：从后台线程取消 callJsMethod —— onCancel 在取消线程同步执行。
        // 修复前直接 box.resume(throwing:) 会与主线程路径并发访问盒子；
        // 修复后 onCancel 统一跳主线程，恰好一次 resume。
        let gateway = PromiseGateway()
        let client = WebviewBridgeClient(gateway: gateway, runtimeFactory: { FakeRuntime() })
        client.initialize(config: WebviewBridgeConfig(bridgeFileName: "wallet-bridge.html"))
        try client.start()
        gateway.onBridgeReady() // 模拟 JS 就绪（FakeRuntime 不会回调 onBridgeReady）

        let task = Task { () -> String in
            try await client.callJsMethod(method: "ping", timeoutMs: 60000, readyWaitMs: 60000)
        }
        // 等调用注册完成（box.continuation 已设置、pending 已入表）
        while gateway.pendingCount == 0 {
            await Task.yield()
        }

        let canceller = Task.detached { task.cancel() }
        await canceller.value

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // 符合预期：恰好一次 resume（未 double-resume 崩溃）
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(gateway.pendingCount, 0, "取消后 pending 已移除")

        client.destroy()
    }
}

/// 最小 Fake：不创建真实 WKWebView（轻量，供取消竞态回归测试使用）。
@MainActor
private final class FakeRuntime: WebViewRuntime {
    let userContentController = WKUserContentController()
    var navigationDelegate: WKNavigationDelegate?
    var isHidden = false

    func loadBridgeFile(_: URL, allowingReadAccessTo _: URL) {}
    func runJavaScript(_: String) async throws -> Any? {
        nil
    }

    func stopLoading() {}
    func loadBlank() {}
    func teardown() {}
}
