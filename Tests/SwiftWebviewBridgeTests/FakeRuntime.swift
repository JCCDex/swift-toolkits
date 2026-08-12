import Foundation
@testable import SwiftWebviewBridge
import WebKit

@MainActor
final class FakeRuntime: WebViewRuntime {
    var loadedURL: URL?
    var loadedReadAccessDirectory: URL?
    var recordedScripts: [String] = []
    var onEvaluate: ((String) -> Void)?
    var stopLoadingCount = 0
    var loadBlankCount = 0
    var teardownCount = 0

    let userContentController = WKUserContentController()
    var navigationDelegate: WKNavigationDelegate?
    var isHidden = false

    func loadBridgeFile(_ url: URL, allowingReadAccessTo directory: URL) {
        self.loadedURL = url
        self.loadedReadAccessDirectory = directory
    }

    func runJavaScript(_ script: String) async throws -> Any? {
        self.recordedScripts.append(script)
        self.onEvaluate?(script)
        return nil
    }

    func stopLoading() {
        self.stopLoadingCount += 1
    }

    func loadBlank() {
        self.loadBlankCount += 1
    }

    func teardown() {
        self.teardownCount += 1
    }
}
