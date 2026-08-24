@testable import SwiftWebviewBridge
import XCTest

@MainActor
final class PromiseGatewayTests: XCTestCase {

    // MARK: - 就绪监听

    func test_onBridgeReady_releasesReadyListeners() {
        let gateway = PromiseGateway()
        var called = false

        _ = gateway.addReadyListener { _ in called = true }

        XCTAssertFalse(called)
        gateway.onBridgeReady()

        XCTAssertTrue(called)
        XCTAssertTrue(gateway.isReady)
    }

    func test_addReadyListener_invokesImmediatelyWhenAlreadyReady() {
        let gateway = PromiseGateway()
        gateway.onBridgeReady()

        var called = false
        _ = gateway.addReadyListener { _ in called = true }

        XCTAssertTrue(called)
    }

    func test_addReadyListener_returnsRemoverThatRemovesPendingListener() {
        let gateway = PromiseGateway()
        var called = false

        let remover = gateway.addReadyListener { _ in called = true }
        remover()
        gateway.onBridgeReady()

        XCTAssertFalse(called)
    }

    func test_resetReady_clearsState() {
        let gateway = PromiseGateway()
        gateway.onBridgeReady()

        gateway.resetReady()

        XCTAssertFalse(gateway.isReady)
        XCTAssertEqual(gateway.pendingCount, 0)
    }

    func test_resetReady_failsPendingWaitersImmediately() async throws {
        // review P1#2：resetReady 不静默丢弃 ready-waiters——等待方立即收到错误而非挂到超时
        let gateway = PromiseGateway()
        let started = expectation(description: "wait started")

        let waiter = Task { () -> Error? in
            started.fulfill()
            do {
                try await gateway.waitForReady(timeoutMs: 60000)
                return nil
            } catch {
                return error
            }
        }
        await fulfillment(of: [started], timeout: 2)
        // 让 waiter 挂起后 resetReady
        gateway.resetReady()

        let error = await waiter.value
        let bridgeError = try XCTUnwrap(error as? WebViewBridgeError)
        XCTAssertEqual(bridgeError, .webViewUnavailable, "resetReady 以 webViewUnavailable 恢复等待方")
    }

    func test_remove_cancelsAttachedJsTask() async {
        // review P1#1：remove 时取消补挂的 in-flight JS 任务
        let gateway = PromiseGateway()
        let id = "id-js"
        gateway.register(id: id, timeoutMs: 60000) { _ in }

        let jsTask = Task<Void, Never> { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 模拟 JS 卡死
        }
        gateway.attachJsTask(id: id, jsTask)
        gateway.remove(id: id)

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(jsTask.isCancelled, "remove 应取消 in-flight JS 任务")
    }

    func test_sleepNanoseconds_clampsInvalidInputs() {
        // review P1#3：负值/NaN/Infinity 不 trap；正数至少 1ns（避免 <1ns 截断为 0 立即超时）
        XCTAssertEqual(PromiseGateway.sleepNanoseconds(-1), 0)
        XCTAssertEqual(PromiseGateway.sleepNanoseconds(0), 0)
        XCTAssertEqual(PromiseGateway.sleepNanoseconds(.nan), 0)
        XCTAssertEqual(PromiseGateway.sleepNanoseconds(.infinity), 0)
        XCTAssertEqual(PromiseGateway.sleepNanoseconds(0.0000001), 1, "0.1ns 向上取整为 1ns，避免截断为 0")
        XCTAssertEqual(PromiseGateway.sleepNanoseconds(1.5), 1_500_000)
    }

    // MARK: - 回调表

    func test_onPromiseResult_removesCallbackAndInvokesIt() {
        let gateway = PromiseGateway()
        let id = "id-1"
        var payload: Result<String, Error>?

        gateway.register(id: id, timeoutMs: 60000) { result in
            payload = result
        }
        gateway.onPromiseResult(id: id, resultJson: #"{"result":"ok"}"#)

        XCTAssertEqual(gateway.pendingCount, 0)
        XCTAssertEqual(try? payload?.get(), "ok")
    }

    func test_onPromiseResult_ignoresUnknownId() {
        let gateway = PromiseGateway()

        gateway.onPromiseResult(id: "missing", resultJson: #"{"result":"ok"}"#)

        XCTAssertEqual(gateway.pendingCount, 0)
    }

    func test_register_timesOutWhenNoResult() async {
        let gateway = PromiseGateway()

        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            gateway.register(id: "slow", timeoutMs: 30) { result in
                continuation.resume(returning: result)
            }
        }

        guard case let .failure(error) = result else {
            XCTFail("expected timeout failure")
            return
        }
        XCTAssertEqual(error as? WebViewBridgeError, .timeout)
        XCTAssertEqual(gateway.pendingCount, 0)
    }

    func test_clearAll_resetsReadyAndCallbacks() {
        let gateway = PromiseGateway()
        gateway.register(id: "id-1", timeoutMs: 60000) { _ in }
        gateway.onBridgeReady()

        gateway.clearAll()

        XCTAssertFalse(gateway.isReady)
        XCTAssertEqual(gateway.pendingCount, 0)
    }

    func test_clearAll_resumesPendingCallbacksWithError() {
        // P0-3 回归：clearAll 必须恢复 pending 调用者——否则其续体永久悬挂
        let gateway = PromiseGateway()
        var results: [Result<String, Error>] = []
        gateway.register(id: "id-1", timeoutMs: 60000) { results.append($0) }
        gateway.register(id: "id-2", timeoutMs: 60000) { results.append($0) }

        gateway.clearAll()

        XCTAssertEqual(gateway.pendingCount, 0)
        XCTAssertEqual(results.count, 2, "pending 调用者必须被恢复（P0-3：不得悬挂）")
        for result in results {
            XCTAssertEqual(result.failureError as? WebViewBridgeError, .webViewUnavailable)
        }
    }

    // MARK: - waitForReady

    func test_waitForReady_returnsWhenReady() async throws {
        let gateway = PromiseGateway()
        let task = Task { try await gateway.waitForReady(timeoutMs: 5000) }

        await Task.yield()
        gateway.onBridgeReady()

        try await task.value
    }

    func test_waitForReady_timesOut() async {
        let gateway = PromiseGateway()

        do {
            try await gateway.waitForReady(timeoutMs: 30)
            XCTFail("expected timeout")
        } catch let error as WebViewBridgeError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_waitForReady_cancelled() async {
        let gateway = PromiseGateway()
        let task = Task { try await gateway.waitForReady(timeoutMs: 60000) }

        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // 符合预期
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_waitForReady_cancelledFromBackgroundThread_resumesExactlyOnce() async {
        // P0-2 回归：从后台线程取消 —— onCancel 在取消线程同步执行。
        // 修复前 box.cancel() 直接在该线程改写 box 与 gateway.readyListeners，
        // 与主线程的 setup/就绪监听/超时任务并发 → double-resume 崩溃 + 字典数据竞争。
        let gateway = PromiseGateway()
        let task = Task { try await gateway.waitForReady(timeoutMs: 60000) }

        await Task.yield()
        let canceller = Task.detached { task.cancel() }
        await canceller.value

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // 符合预期：恰好一次 resume（未 double-resume 崩溃）
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // 取消后就绪监听已被 remover 清理：再触发就绪不崩溃、不残留
        gateway.onBridgeReady()
        XCTAssertTrue(gateway.isReady)
    }

    // MARK: - 结果解析

    func test_parseResult_returnsStringResult() throws {
        let result = PromiseGateway.parseResult(#"{"result":"ok"}"#)
        XCTAssertEqual(try result.get(), "ok")
    }

    func test_parseResult_coercesNumberToString() throws {
        let result = PromiseGateway.parseResult(#"{"result":123}"#)
        XCTAssertEqual(try result.get(), "123")
    }

    func test_parseResult_serializesObjectResult() throws {
        let result = PromiseGateway.parseResult(#"{"result":{"k":"v"}}"#)
        XCTAssertEqual(try result.get(), #"{"k":"v"}"#)
    }

    func test_parseResult_reportsErrorResponse() {
        let result = PromiseGateway.parseResult(#"{"error":"boom"}"#)
        XCTAssertEqual(result.failureError as? WebViewBridgeError, .jsError("boom"))
    }

    func test_parseResult_reportsInvalidResponseFormat() {
        let result = PromiseGateway.parseResult(#"{"status":"ok"}"#)
        XCTAssertEqual(result.failureError as? WebViewBridgeError, .invalidResponseFormat)
    }

    func test_parseResult_reportsMalformedJson() {
        let result = PromiseGateway.parseResult("not-json")
        XCTAssertEqual(result.failureError as? WebViewBridgeError, .malformedJSON("not-json"))
    }
}

private extension Result {
    var failureError: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}
