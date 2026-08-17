import Foundation
@testable import SwiftDappConnect
import Testing
import WebKit

#if os(iOS)

    /// 真实 WKWebView 集成测试：加载 HTML → 注入 provider JS →
    /// DApp 调 `web3_clientVersion`，验证 JS → `_tw_` → native 路由 → reply 通道 → Promise 的完整链路。
    ///
    /// 说明：真实 WebView 用例只在 iOS 模拟器运行（macOS `swift test` 并行执行对隐藏 WKWebView
    /// 的消息投递不可靠，会偶发超时）；iOS 走 fastlane 串行执行，稳定。
    @Test(.serialized) @MainActor func `real webview web3 client version returns constant`() async throws {
        let (webView, resultWaiter, interface) = try await makeLoadedWebView()

        #expect(await injectProviderJS(into: webView, token: interface.responseToken), "provider JS 未能在页面中生效（可能被重载冲掉）")

        // M1/M2 加固断言：回传入口被冻结、状态不再暴露为可写全局。
        let settleFrozen = try? await webView.evaluateJavaScript(
            "Object.getOwnPropertyDescriptor(window, '_ccdaoSettle').writable === false" +
                " && Object.getOwnPropertyDescriptor(window, '_ccdaoNative').writable === false"
        ) as? Bool
        #expect(settleFrozen == true, "native 回传入口应被冻结为只读")
        let noGlobalState = try? await webView.evaluateJavaScript("typeof window._ccdaoProviderState") as? String
        #expect(noGlobalState == "undefined", "provider 状态不应暴露为可写全局对象")

        // DApp 侧调用：window.ccdao.request 走 native 路由，web3_clientVersion 返回常量。
        // 结果经 testResult 通道回传（成功 result / 失败 error），Swift 以 continuation 等待。
        _ = try await webView.evaluateJavaScript("""
        window.ccdao.request({ method: 'web3_clientVersion' }).then(
          r => window.webkit.messageHandlers.testResult.postMessage({ result: String(r) }),
          e => window.webkit.messageHandlers.testResult.postMessage({ error: String((e && e.message) || e) })
        );
        true;
        """)

        let (result, jsError) = await resultWaiter.waitForResult()

        #expect(jsError == nil, "JS 侧收到错误: \(jsError ?? "")")
        #expect(result == "CCDAO/v1.0.0")

        interface.detach()
    }

    /// 加载真实 WKWebView（注册 _tw_ + testResult 通道，等待 didFinish）。
    @MainActor
    private func makeLoadedWebView() async throws -> (webView: WKWebView, resultWaiter: BridgeResultWaiter, interface: WebAppInterface) {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let interface = DAppConnectSdk.createWebAppInterface(
            webView: webView,
            ethMiddleware: FakeEthMiddleware(),
            swtcMiddleware: FakeSwtcMiddleware()
        )
        // H1 修复后 origin 按消息从 frameInfo.securityOrigin 实时推导：
        // loadHTMLString 的 baseURL 决定页面 origin（此处即 https://dapp.example.com），
        // 不再需要（也不应）调用 setOrigin。
        let resultWaiter = BridgeResultWaiter()
        webView.configuration.userContentController.add(resultWaiter, contentWorld: .page, name: "testResult")

        let waiter = PageLoadWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(
            "<!DOCTYPE html><html><head><meta charset='utf-8'></head><body><h1>dapp</h1></body></html>",
            baseURL: URL(string: "https://dapp.example.com")
        )
        try await waiter.waitForFinish(timeoutSeconds: 30)
        return (webView, resultWaiter, interface)
    }

    /// 真实 WKWebView：EIP-6963 默认 announce 信息（uuid/name/rdns + provider.request 可用）。
    @Test(.serialized) @MainActor func `real webview eip6963 announces provider info`() async throws {
        let (webView, resultWaiter, interface) = try await makeLoadedWebView()

        #expect(await injectProviderJS(into: webView, token: interface.responseToken), "provider JS 未能在页面中生效")

        // 挂监听 + 派发 eip6963:requestProvider 触发重广播（同一段脚本原子执行，避免页面上下文重置）
        _ = try await webView.evaluateJavaScript("""
        window.addEventListener('eip6963:announceProvider', function (e) {
          var payload = JSON.stringify({
              uuid: e.detail.info.uuid,
              name: e.detail.info.name,
              rdns: e.detail.info.rdns,
              hasRequest: typeof e.detail.provider.request === 'function'
          });
          // 同步执行期间 postMessage 不送达（测试进程 quirk），延后到微任务投递
          // （避免 setTimeout——隐藏 WebView 的 timer 可能被节流）
          Promise.resolve().then(function () {
            window.webkit.messageHandlers.testResult.postMessage({ result: payload });
          });
        });
        window.dispatchEvent(new CustomEvent('eip6963:requestProvider'));
        true;
        """)

        let (result, jsError) = await resultWaiter.waitForResult()
        #expect(jsError == nil, "JS 侧收到错误: \(jsError ?? "")")
        guard let result, let data = result.data(using: .utf8) else {
            Issue.record("未收到 announce 结果")
            interface.detach()
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("announce 结果不是合法 JSON")
            interface.detach()
            return
        }

        #expect(object["uuid"] as? String == "ccdao-connector")
        #expect(object["name"] as? String == "CCDAO Connector")
        #expect(object["rdns"] as? String == "com.jccdex.ccdaoconnector")
        #expect(object["hasRequest"] as? Bool == true)

        interface.detach()
    }

    /// 真实 WKWebView：EIP-6963 图标覆盖（loadEip6963IconOverrideJs 注入后 announce 携带自定义 icon）。
    @Test(.serialized) @MainActor func `real webview eip6963 icon override replaces announcement icon`() async throws {
        let (webView, resultWaiter, interface) = try await makeLoadedWebView()
        let customIcon = "data:image/png;base64,AAAA"

        // 覆盖脚本必须早于 provider 注入（它 patch 了 window.dispatchEvent）
        _ = try await webView.evaluateJavaScript(
            DAppConnectSdk.loadEip6963IconOverrideJs(iconDataUri: customIcon) + "; true;"
        )
        #expect(await injectProviderJS(into: webView, token: interface.responseToken), "provider JS 未能在页面中生效")

        // 挂监听 + 派发 requestProvider 触发重广播（原子执行）
        _ = try await webView.evaluateJavaScript("""
        window.addEventListener('eip6963:announceProvider', function (e) {
          var icon = e.detail.info.icon;
          Promise.resolve().then(function () {
            window.webkit.messageHandlers.testResult.postMessage({ result: icon });
          });
        });
        window.dispatchEvent(new CustomEvent('eip6963:requestProvider'));
        true;
        """)

        let (result, jsError) = await resultWaiter.waitForResult()
        #expect(jsError == nil, "JS 侧收到错误: \(jsError ?? "")")
        #expect(result == customIcon)

        interface.detach()
    }

    /// 注入 EIP-1193 provider JS（宿主标准用法：必须带 interface.responseToken，M1/M2）。
    /// 注入后校验状态标记，确认页面内已生效。
    @MainActor
    private func injectProviderJS(into webView: WKWebView, token: String) async -> Bool {
        _ = try? await webView.evaluateJavaScript(DAppConnectSdk.loadProviderJs(token: token) + "; true;")
        let state = try? await webView.evaluateJavaScript("typeof window.ethereum") as? String
        return state == "object"
    }

    /// 等待 JS 侧经 `testResult` 消息通道回传结果（非轮询，continuation 等待 + 超时兜底）。
    @MainActor
    private final class BridgeResultWaiter: NSObject, WKScriptMessageHandler {
        private var continuation: CheckedContinuation<(result: String?, error: String?), Never>?
        private var timeoutTask: Task<Void, Never>?

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            let outcome: (result: String?, error: String?) = (
                body["result"] as? String,
                body["error"] as? String
            )
            self.timeoutTask?.cancel()
            self.continuation?.resume(returning: outcome)
            self.continuation = nil
        }

        func waitForResult(timeoutSeconds: TimeInterval = 60) async -> (result: String?, error: String?) {
            await withCheckedContinuation { (continuation: CheckedContinuation<(result: String?, error: String?), Never>) in
                self.continuation = continuation
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    self?.resumeIfPending(returning: (nil, "timeout"))
                }
                self.timeoutTask = timeoutTask
            }
        }

        private func resumeIfPending(returning outcome: (result: String?, error: String?)) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: outcome)
        }
    }

    /// 等待一次页面加载完成（didFinish）。
    @MainActor
    private final class PageLoadWaiter: NSObject, WKNavigationDelegate {
        private(set) var finished = false
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            self.finished = true
            self.timeoutTask?.cancel()
            self.continuation?.resume()
            self.continuation = nil
        }

        func waitForFinish(timeoutSeconds: TimeInterval) async throws {
            if self.finished {
                return
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    self?.resumeIfPending(throwing: TimeoutError.pageLoadTimedOut)
                }
                self.timeoutTask = timeoutTask
            }
        }

        private func resumeIfPending(throwing error: TimeoutError) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }

        private enum TimeoutError: Error {
            case pageLoadTimedOut
        }
    }

#endif
