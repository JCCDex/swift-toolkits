import SwiftDappConnect
import SwiftUI
import SwiftWallet
import WebKit

/// DApp 容器：真实 WKWebView + SwiftDappConnect 注入的 EIP-1193 provider。
///
/// 页面用 `load(Data, ... baseURL: "https://dapp.example.com")` 加载：
/// - 让页面拥有合法 http(s) origin（H1 修复后 origin 按 frameInfo.securityOrigin
///   实时推导，file:// / about:blank 会被拒绝）；
/// - 编码：文件原始 UTF-8 字节 + UTF-8 BOM 前置，杜绝任何 WebKit 编码嗅探；
/// - provider JS 在页面加载完成后注入（幂等，SPA 重载也不重复注册）。
struct DappView: UIViewRepresentable {
    let wallet: WalletService

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var interface: WebAppInterface?

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            guard let interface else { return }
            // 注入 EIP-1193 provider（带 responseToken，native 回传才被信任，M1/M2）
            webView.evaluateJavaScript(
                DAppConnectSdk.loadProviderJs(token: interface.responseToken)
            ) { _, _ in }
            // 初始化链状态（Ethereum：chainId 0x1，与 DemoAccountProvider 的 .eth 一致）
            webView.evaluateJavaScript(
                interface.loadInitJs(chainIdHex: "0x1", rpcUrl: "https://rpc.example.com")
            ) { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        // 签名后端：SwiftWallet（幂等启动，复用同一隐藏 WebView 桥）
        try? SwiftWallet.shared.start()

        let accountProvider = DemoAccountProvider(state: wallet.state)
        // 密钥 Provider：从 SwiftVault 取当前钱包私钥（DApp 的 eth_signTransaction 走这里）
        let secretProvider = DemoSecretProvider { [weak wallet] address in
            await wallet?.privateKey(for: address)
        }
        let eth = DAppConnectSdk.createEthMiddleware(
            accountProvider: accountProvider,
            secretProvider: secretProvider,
            nodeProvider: DemoNodeProvider(),
            initialChain: .eth,
            signing: SwiftWallet.shared
        )
        // demo 自动授权 eth_requestAccounts（真实 App 这里应弹用户确认）
        eth.setRequestAccountsCallback { _ in true }
        let swtc = DAppConnectSdk.createSwtcMiddleware(
            accountProvider: accountProvider,
            secretProvider: secretProvider,
            nodeProvider: DemoNodeProvider(),
            signing: SwiftWallet.shared
        )
        let interface = DAppConnectSdk.createWebAppInterface(
            webView: webView,
            ethMiddleware: eth,
            swtcMiddleware: swtc,
            accountProvider: accountProvider,
            secretProvider: secretProvider
        )
        context.coordinator.interface = interface
        webView.navigationDelegate = context.coordinator

        // 加载本地 DApp 页面（英文描述，规避非 ASCII 编码问题；字节级 UTF-8 + BOM 双保险）。
        guard
            let htmlURL = Bundle.main.url(forResource: "dapp", withExtension: "html"),
            let fileBytes = try? Data(contentsOf: htmlURL)
        else {
            return webView
        }
        var utf8WithBOM = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        utf8WithBOM.append(fileBytes)
        webView.load(
            utf8WithBOM,
            mimeType: "text/html",
            characterEncodingName: "utf-8",
            baseURL: URL(string: "https://dapp.example.com")!
        )
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}
