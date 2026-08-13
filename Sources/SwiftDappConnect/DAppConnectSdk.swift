import Foundation
import WebKit

/// SwiftDappConnect 统一入口：中间件工厂、JS 生成、URL 安全。
public enum DAppConnectSdk {

    // MARK: - 中间件工厂

    @MainActor
    public static func createEthMiddleware(
        accountProvider: any AccountProvider,
        secretProvider: any SecretProvider,
        nodeProvider: any NodeProvider,
        chainProvider: (any ChainProvider)? = nil,
        initialChain: ChainType = .bsc,
        signing: any WalletSigning
    ) -> EthMiddleware {
        EthMiddleware(
            accountProvider: accountProvider,
            secretProvider: secretProvider,
            nodeProvider: nodeProvider,
            chainProvider: chainProvider,
            initialChain: initialChain,
            signing: signing
        )
    }

    @MainActor
    public static func createSwtcMiddleware(
        accountProvider: any AccountProvider,
        secretProvider: any SecretProvider,
        nodeProvider: any NodeProvider,
        signing: any WalletSigning
    ) -> SwtcMiddleware {
        SwtcMiddleware(
            accountProvider: accountProvider,
            secretProvider: secretProvider,
            nodeProvider: nodeProvider,
            signing: signing
        )
    }

    // MARK: - WebAppInterface 工厂

    /// 创建并挂载 WebAppInterface：
    /// 注册 `_tw_` 消息处理器 + 注入 `window._tw_` 适配脚本。
    @MainActor
    public static func createWebAppInterface(
        webView: WKWebView,
        ethMiddleware: any EthMiddlewareProtocol,
        swtcMiddleware: any SwtcMiddlewareProtocol,
        accountProvider: (any AccountProvider)? = nil,
        secretProvider: (any SecretProvider)? = nil,
        nftProvider: (any NftProvider)? = nil,
        didSDK: (any DidSDK)? = nil,
        didDocumentMutationListener: DidDocumentMutationListener? = nil
    ) -> WebAppInterface {
        let interface = WebAppInterface(
            ethMiddleware: ethMiddleware,
            swtcMiddleware: swtcMiddleware,
            accountProvider: accountProvider,
            secretProvider: secretProvider,
            nftProvider: nftProvider,
            didSDK: didSDK,
            didDocumentMutationListener: didDocumentMutationListener
        )
        interface.attach(to: webView)
        return interface
    }

    // MARK: - Provider JS

    /// 加载 EIP-1193 provider 脚本（iOS 传输变体，实现 window.ethereum / window.ccdao）。
    public static func loadProviderJs() -> String {
        guard
            let url = Bundle.module.url(forResource: "ccdao-eip1193-provider-ios", withExtension: "js"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return text
    }

    /// 初始化 JS：设置 chainId / rpcUrl 到 provider 状态。
    public static func loadInitJs(chainIdHex: String, rpcUrl: String) -> String {
        let chain = self.jsQuote(chainIdHex)
        let rpc = self.jsQuote(rpcUrl)
        return """
        (function () {
          try {
            if (window._ccdaoProviderState) {
              window._ccdaoProviderState.chainId = \(chain);
              window._ccdaoProviderState.rpcUrl = \(rpc);
              console.log('[CCDAO Init] Provider state updated: chainId=\(chain) rpcUrl=\(rpc)');
            }
          } catch (e) {
            console.error('[CCDAO Init] Failed to update provider', e);
          }
        })();
        """
    }

    /// 推送选中地址变更。
    public static func loadAddressJs(address: String, isSwtc: Bool) -> String {
        let fn = isSwtc ? "_updateSwtcSelectedAddress" : "_updateSelectedAddress"
        return "if (window.\(fn)) { window.\(fn)(\(self.jsQuote(address))); }"
    }

    /// 推送链切换并触发 chainChanged。
    public static func loadUpdateChainIdJs(chainIdHex: String, rpcUrl: String) -> String {
        "if (window._updateChainId) { window._updateChainId(\(self.jsQuote(chainIdHex)), \(self.jsQuote(rpcUrl))); }"
    }

    /// 覆盖 EIP-6963 announce 的钱包图标。
    public static func loadEip6963IconOverrideJs(iconDataUri: String) -> String {
        let escaped = iconDataUri
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function(){var i='\(escaped)';var o=window.dispatchEvent.bind(window);window.dispatchEvent=function(e){if(e.type==='eip6963:announceProvider'&&e.detail&&e.detail.info){var n={uuid:e.detail.info.uuid,name:e.detail.info.name,icon:i,rdns:e.detail.info.rdns};var ne=new CustomEvent('eip6963:announceProvider',{detail:{info:Object.freeze(n),provider:e.detail.provider}});o(ne);return true}return o(e)}})();
        """
    }

    // MARK: - URL 安全

    /// 校验 URL 使用 http/https 且 host 合法；拒绝 file://、javascript: 等。
    public static func isSafeUrl(_ url: String) -> Bool {
        let pattern = #"^(https?)://[a-zA-Z0-9][-a-zA-Z0-9]{0,62}(\.[a-zA-Z0-9][-a-zA-Z0-9]{0,62})+\.?(:[0-9]{1,5})?(/.*)?$"#
        return url.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 内置 SVG「D」盾兜底图标。
    public static let defaultIconDataURI =
        "data:image/svg+xml," +
        "%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 56 56'%3E" +
        "%3Crect width='56' height='56' rx='16' fill='%233B82F6'/%3E" +
        "%3Ctext x='28' y='38' text-anchor='middle' fill='white' font-size='32' " +
        "font-family='Arial,sans-serif' font-weight='bold'%3ED%3C/text%3E" +
        "%3C/svg%3E"

    // MARK: - 内部

    /// `window._tw_` 适配脚本：把 DApp 侧 postMessage 接到 WebKit 消息通道。
    static let adapterScript = """
    (function () {
      if (window._tw_) return;
      window._tw_ = {
        postMessage: function (json, replyHandler) {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers._tw_) {
            window.webkit.messageHandlers._tw_.postMessage(json, replyHandler);
          } else {
            console.error('[CCDAO] _tw_ bridge not available');
          }
        }
      };
    })();
    """

    private static func jsQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

private extension WebAppInterface {
    func attach(to webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        // legacy WKScriptMessageHandler（配合 evaluateJavaScript 回传，见 WebAppInterface.deliver）
        controller.add(self, contentWorld: .page, name: Self.handlerName)
        controller.addUserScript(
            WKUserScript(
                source: DAppConnectSdk.adapterScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }
}
