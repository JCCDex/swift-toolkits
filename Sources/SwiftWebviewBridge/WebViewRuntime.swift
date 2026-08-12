import Foundation
import WebKit

/// WebView 操作抽象：单测注入 Fake 替代真实 WKWebView（对应 Kotlin 的 webViewFactory 注入）。
@MainActor
protocol WebViewRuntime: AnyObject {
    var userContentController: WKUserContentController { get }
    var navigationDelegate: WKNavigationDelegate? { get set }
    var isHidden: Bool { get set }

    func loadBridgeFile(_ url: URL, allowingReadAccessTo directory: URL)
    func runJavaScript(_ script: String) async throws -> Any?
    func stopLoading()
    func loadBlank()
    func teardown()
}

@MainActor
extension WKWebView: WebViewRuntime {
    var userContentController: WKUserContentController {
        configuration.userContentController
    }

    func loadBridgeFile(_ url: URL, allowingReadAccessTo directory: URL) {
        loadFileURL(url, allowingReadAccessTo: directory)
    }

    func runJavaScript(_ script: String) async throws -> Any? {
        try await evaluateJavaScript(script)
    }

    func loadBlank() {
        load(URLRequest(url: URL(string: "about:blank")!))
    }

    func teardown() {
        stopLoading()
        configuration.userContentController.removeAllUserScripts()
        configuration.userContentController.removeAllScriptMessageHandlers()
    }
}
