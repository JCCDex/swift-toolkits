import Foundation
import SwiftCore
import WebKit
#if canImport(UIKit)
    import UIKit
#endif

/// DApp 应用内浏览器宿主状态(与两端共享页面 `DAppBrowserScreen` 的状态模型同形)。
public struct DappWebViewHostState: Sendable, Equatable {
    public var title: String
    public var progress: Int
    public var canGoBack: Bool
    public var loaded: Bool
    public var failed: Bool

    public init(
        title: String = "",
        progress: Int = 0,
        canGoBack: Bool = false,
        loaded: Bool = false,
        failed: Bool = false
    ) {
        self.title = title
        self.progress = progress
        self.canGoBack = canGoBack
        self.loaded = loaded
        self.failed = failed
    }
}

/// 宿主状态回调(宿主在状态变化时通知宿主层)。
@MainActor
public protocol DappWebViewHostDelegate: AnyObject {
    func dappWebViewHost(_ host: DappWebViewHost, didChangeState state: DappWebViewHostState)
}

/// 宿主配置:provider 图与页面脚本由调用方(宿主 App)提供,宿主只负责 WKWebView 管线。
///
/// - `preProviderScripts`: provider 脚本(文档开始注入)之前评估的脚本
/// - `postProviderScripts`: provider 就绪后评估的脚本(依赖 provider 的 patch)
@MainActor
public struct DappWebViewHostConfiguration {
    public var ethMiddleware: any EthMiddlewareProtocol
    public var swtcMiddleware: any SwtcMiddlewareProtocol
    public var accountProvider: (any AccountProvider)?
    public var secretProvider: (any SecretProvider)?
    public var nftProvider: (any NftProvider)?
    public var didSDK: (any DidSDK)?
    public var approveConnect: RequestAccountsCallback?
    public var preProviderScripts: [String]
    public var postProviderScripts: [String]
    public var isInternalPreviewURL: (String?) -> Bool
    public var onPageStarted: ((String) -> Void)?
    public var onPageFinished: ((String) -> Void)?
    public var allowsBackForwardNavigationGestures: Bool

    public init(
        ethMiddleware: any EthMiddlewareProtocol,
        swtcMiddleware: any SwtcMiddlewareProtocol,
        accountProvider: (any AccountProvider)? = nil,
        secretProvider: (any SecretProvider)? = nil,
        nftProvider: (any NftProvider)? = nil,
        didSDK: (any DidSDK)? = nil,
        approveConnect: RequestAccountsCallback? = nil,
        preProviderScripts: [String] = [],
        postProviderScripts: [String] = [],
        isInternalPreviewURL: @escaping (String?) -> Bool = { _ in false },
        onPageStarted: ((String) -> Void)? = nil,
        onPageFinished: ((String) -> Void)? = nil,
        allowsBackForwardNavigationGestures: Bool = true
    ) {
        self.ethMiddleware = ethMiddleware
        self.swtcMiddleware = swtcMiddleware
        self.accountProvider = accountProvider
        self.secretProvider = secretProvider
        self.nftProvider = nftProvider
        self.didSDK = didSDK
        self.approveConnect = approveConnect
        self.preProviderScripts = preProviderScripts
        self.postProviderScripts = postProviderScripts
        self.isInternalPreviewURL = isInternalPreviewURL
        self.onPageStarted = onPageStarted
        self.onPageFinished = onPageFinished
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
    }
}

/// DApp 应用内浏览器宿主(WKWebView 管线):WebView 装配、`_tw_` provider 接口与 provider 脚本注入、
/// 标题/进度/可后退状态推送、安全 URL 策略与 target=_blank 就地加载。
///
/// 语义与 Android 侧 `DappWebViewHost`(kotlin-toolkits)一一对应;业务编排(授权持久化、
/// 地址推送、保险库取钥、文件选择、blob 落盘)留在宿主 App。
@MainActor
public final class DappWebViewHost: NSObject {
    public private(set) var state = DappWebViewHostState()

    public weak var delegate: DappWebViewHostDelegate?

    /// 承载页面的 WKWebView(宿主渲染同一实例)。
    public let webView: WKWebView

    /// provider 桥接口(会话创建后可用;`responseToken` 供宿主推送 dappInit/setAddress 等)。
    public private(set) var webAppInterface: WebAppInterface?

    private let configuration: DappWebViewHostConfiguration
    private var observations: [NSKeyValueObservation] = []
    #if os(iOS)
        private var openPanelDelegate: DappOpenPanelDelegate?
    #endif

    public init(configuration: DappWebViewHostConfiguration) {
        self.configuration = configuration
        let webViewConfiguration = WKWebViewConfiguration()
        #if os(iOS)
            webViewConfiguration.allowsInlineMediaPlayback = true
        #endif
        self.webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        #if os(iOS)
            self.webView.allowsBackForwardNavigationGestures = configuration.allowsBackForwardNavigationGestures
        #endif
        self.observeWebView()
    }

    /// 打开(或切换)会话并加载 URL;返回 false = URL 不安全或依赖未就绪(置 `failed`)。
    @discardableResult
    public func open(url rawUrl: String) -> Bool {
        guard DAppConnectSdk.isSafeUrl(rawUrl), let url = URL(string: rawUrl) else {
            self.update(failed: true)
            return false
        }
        if self.webAppInterface == nil {
            self.createSession()
        }
        guard self.webAppInterface != nil else {
            self.update(failed: true)
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        self.webView.load(request)
        self.update(loaded: true, failed: false)
        return true
    }

    /// 后退一页(无历史时不动)。
    public func goBack() {
        if self.webView.canGoBack {
            self.webView.goBack()
        }
    }

    public func reload() {
        self.webView.reload()
    }

    /// 结束当前页面:停止加载;会话(中间件/WebView)保留以复用(与既有 iOS 会话语义一致)。
    public func close() {
        self.webView.stopLoading()
        self.update(progress: 0, canGoBack: false)
    }

    /// 在页面上下文评估脚本(宿主推送 provider 状态/守卫恢复等)。
    public func evaluate(_ script: String) {
        guard !script.isEmpty else { return }
        self.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - 会话

    private func createSession() {
        let eth = self.configuration.ethMiddleware
        let swtc = self.configuration.swtcMiddleware
        if let approve = configuration.approveConnect {
            eth.setRequestAccountsCallback(approve)
            swtc.setRequestAccountsCallback(approve)
        }
        let interface = DAppConnectSdk.createWebAppInterface(
            webView: self.webView,
            ethMiddleware: eth,
            swtcMiddleware: swtc,
            accountProvider: self.configuration.accountProvider,
            secretProvider: self.configuration.secretProvider,
            nftProvider: self.configuration.nftProvider,
            didSDK: self.configuration.didSDK,
            didDocumentMutationListener: nil
        )
        self.webAppInterface = interface
        // provider 脚本(带 responseToken 鉴权)作为 documentStart 用户脚本,每次导航自动注入。
        self.webView.configuration.userContentController.addUserScript(
            WKUserScript(
                source: DAppConnectSdk.loadProvider(token: interface.responseToken),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    private func injectPageScripts() {
        self.configuration.preProviderScripts.forEach { self.evaluate($0) }
        self.configuration.postProviderScripts.forEach { self.evaluate($0) }
    }

    // MARK: - 状态

    private func observeWebView() {
        self.observations = [
            self.webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncProgress() }
            },
            self.webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncTitle() }
            },
            self.webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncCanGoBack() }
            }
        ]
    }

    private func syncProgress() {
        self.update(progress: Int((self.webView.estimatedProgress * 100).rounded()))
    }

    private func syncTitle() {
        let title = self.webView.title ?? ""
        if !title.isEmpty {
            self.update(title: title)
        }
    }

    private func syncCanGoBack() {
        self.update(canGoBack: self.webView.canGoBack)
    }

    private func update(
        title: String? = nil,
        progress: Int? = nil,
        canGoBack: Bool? = nil,
        loaded: Bool? = nil,
        failed: Bool? = nil
    ) {
        let next =
            DappWebViewHostState(
                title: title ?? self.state.title,
                progress: progress ?? self.state.progress,
                canGoBack: canGoBack ?? self.state.canGoBack,
                loaded: loaded ?? self.state.loaded,
                failed: failed ?? self.state.failed
            )
        guard next != self.state else { return }
        self.state = next
        self.delegate?.dappWebViewHost(self, didChangeState: next)
    }
}

// MARK: - WKNavigationDelegate

extension DappWebViewHost: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        self.update(progress: 0, failed: false)
        self.configuration.onPageStarted?(url)
        if self.configuration.isInternalPreviewURL(webView.url?.absoluteString) {
            return
        }
        self.injectPageScripts()
    }

    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        self.update(progress: 100, canGoBack: webView.canGoBack)
        if self.configuration.isInternalPreviewURL(webView.url?.absoluteString) {
            self.syncTitle()
            return
        }
        self.injectPageScripts()
        self.syncTitle()
        self.configuration.onPageFinished?(webView.url?.absoluteString ?? "")
    }

    /// 仅放行 http/https(与 `DAppConnectSdk.isSafeUrl` 一致);其它 scheme 一律拦截。
    public func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           DAppConnectSdk.isSafeUrl(url.absoluteString) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}

// MARK: - WKUIDelegate

extension DappWebViewHost: WKUIDelegate {
    // `<input type=file>`:弹出系统文稿选择器并把结果回填给 WebKit(Android 侧由宿主 App 的
    // SAF 选择器承担同一职责)。
    #if os(iOS)
        /// `WKOpenPanelParameters` 需要 iOS 18.4+;更早系统由宿主 App 的 JS 兜底(拦截 input[type=file])。
        @available(iOS 18.4, *)
        public func webView(
            _: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame _: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .item], asCopy: true)
            picker.allowsMultipleSelection = parameters.allowsMultipleSelection
            let delegate = DappOpenPanelDelegate(completionHandler: completionHandler)
            picker.delegate = delegate
            self.openPanelDelegate = delegate
            guard let presenter = DappOpenPanelDelegate.topViewController() else {
                self.openPanelDelegate = nil
                completionHandler(nil)
                return
            }
            presenter.present(picker, animated: true)
        }
    #endif

    /// `target=_blank` 新窗口:在当前 WebView 内加载(不弹新窗口)。
    public func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           DAppConnectSdk.isSafeUrl(url.absoluteString) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

#if os(iOS)
    /// 文稿选择器回调桥:把选择结果回填 WebKit;取消则回 nil。
    final class DappOpenPanelDelegate: NSObject, UIDocumentPickerDelegate {
        private let completionHandler: ([URL]?) -> Void
        private var finished = false

        init(completionHandler: @escaping ([URL]?) -> Void) {
            self.completionHandler = completionHandler
            super.init()
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            self.finish(urls.isEmpty ? nil : urls)
        }

        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
            self.finish(nil)
        }

        private func finish(_ urls: [URL]?) {
            guard !self.finished else { return }
            self.finished = true
            MainActor.assumeIsolated { self.completionHandler(urls) }
        }

        /// 当前顶层控制器(用于呈现文稿选择器)。
        @MainActor
        static func topViewController() -> UIViewController? {
            let keyWindow =
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first { $0.isKeyWindow }
            guard var top = keyWindow?.rootViewController else { return nil }
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
    }
#endif
