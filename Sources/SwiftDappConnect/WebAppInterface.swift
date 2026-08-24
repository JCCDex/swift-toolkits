import Foundation
import OSLog
import SwiftCore
import WebKit

/// `_tw_` 接收端：把 DApp 的 postMessage 路由到对应中间件，并经 reply 通道回传。
@MainActor
public final class WebAppInterface: NSObject, WKScriptMessageHandler {
    public static let handlerName = "_tw_"
    /// P1#13：非 DAppConnectError 的内部错误记日志（只打 domain#code，不落 payload）。
    private static let logger = Logger(subsystem: "com.jccdex.toolkits.swiftdappconnect", category: "WebAppInterface")

    private let ethMiddleware: any EthMiddlewareProtocol
    private let swtcMiddleware: any SwtcMiddlewareProtocol
    private let accountProvider: (any AccountProvider)?
    private let secretProvider: (any SecretProvider)?
    private let nftProvider: (any NftProvider)?
    private let didSDK: (any DidSDK)?
    private let didDocumentMutationListener: DidDocumentMutationListener?

    weak var webView: WKWebView?
    private var chainProvider: (any ChainProvider)?
    private var onAccountSwitched: ((String) -> Void)?

    /// Native → JS 回传鉴权 token（M1/M2）：注入 provider 闭包后，`_ccdaoSettle` /
    /// `_ccdaoNative` 校验它才执行。页面 JS 读不到该值，无法伪造响应或状态推送。
    /// 宿主注入 provider 时必须用 `DAppConnectSdk.loadProvider(token: self.responseToken)`。
    public let responseToken: String

    public init(
        ethMiddleware: any EthMiddlewareProtocol,
        swtcMiddleware: any SwtcMiddlewareProtocol,
        accountProvider: (any AccountProvider)? = nil,
        secretProvider: (any SecretProvider)? = nil,
        nftProvider: (any NftProvider)? = nil,
        didSDK: (any DidSDK)? = nil,
        didDocumentMutationListener: DidDocumentMutationListener? = nil
    ) {
        self.ethMiddleware = ethMiddleware
        self.swtcMiddleware = swtcMiddleware
        self.accountProvider = accountProvider
        self.secretProvider = secretProvider
        self.nftProvider = nftProvider
        self.didSDK = didSDK
        self.didDocumentMutationListener = didDocumentMutationListener
        self.responseToken = Self.makeResponseToken()
        super.init()
    }

    // MARK: - Native → JS 推送（带 token 鉴权，避免宿主漏传导致静默失效）

    /// 等价 `DAppConnectSdk.dappInit(chainIdHex:rpcUrl:token:)`，token 自动带上。
    public func dappInit(chainIdHex: String, rpcUrl: String) -> String {
        DAppConnectSdk.dappInit(chainIdHex: chainIdHex, rpcUrl: rpcUrl, token: self.responseToken)
    }

    /// 等价 `DAppConnectSdk.setAddress(address:isSwtc:token:)`，token 自动带上。
    public func setAddress(address: String, isSwtc: Bool) -> String {
        DAppConnectSdk.setAddress(address: address, isSwtc: isSwtc, token: self.responseToken)
    }

    /// 等价 `DAppConnectSdk.setChainId(chainIdHex:rpcUrl:token:)`，token 自动带上。
    public func setChainId(chainIdHex: String, rpcUrl: String) -> String {
        DAppConnectSdk.setChainId(chainIdHex: chainIdHex, rpcUrl: rpcUrl, token: self.responseToken)
    }

    private static func makeResponseToken() -> String {
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        return Hex.encode(bytes)
    }

    /// 宿主在导航时设置 DApp origin（M-05，Kotlin 迁移契约）。
    ///
    /// - Important: 已废弃。H1 修复后授权 origin 改为按消息从 `frameInfo.securityOrigin`
    ///   实时推导（且仅接受主 frame 消息），不再读取宿主设置的全局值。
    ///   保留此方法仅为兼容旧接入代码；调用不再影响任何授权判定。
    @available(*, deprecated, message: "origin 已按消息从 frameInfo.securityOrigin 自动推导，无需（也不应）再调用 setOrigin")
    public func setOrigin(_ origin: String) {
        _ = origin
    }

    /// 设置链切换 Provider（legacy；链切换主要走中间件构造注入的 chainProvider）。
    public func setChainProvider(_ provider: any ChainProvider) {
        self.chainProvider = provider
        self.ethMiddleware.setOnAccountSwitched { [weak self] newAddress in
            self?.onAccountSwitched?(newAddress)
        }
    }

    public func setOnAccountSwitched(_ callback: @escaping (String) -> Void) {
        self.onAccountSwitched = callback
    }

    /// 从 WebView 注销消息处理器（宿主释放界面时调用，避免 retain cycle）。
    public func detach() {
        self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        self.webView = nil
    }

    // MARK: - WKScriptMessageHandler（legacy）

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        _ = userContentController

        // 先提取值类型（WKScriptMessage/WKSecurityOrigin 非 Sendable，不能跨线程捕获）：
        let bodyText = message.body as? String
        let isMainFrame = message.frameInfo.isMainFrame
        let scheme = message.frameInfo.securityOrigin.protocol
        let host = message.frameInfo.securityOrigin.host
        let port = message.frameInfo.securityOrigin.port

        // JSON 解析移出主线程（大 NFT/DID payload 的 JSONSerialization 会卡 UI，见 review E-1）：
        // 主线程 Task 等待 detached 解析结果，再继续授权/路由（self 为 @MainActor）。
        Task { @MainActor [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) { () -> ParsedMessage in
                let obj: [String: Any]? = if let bodyText {
                    Json.parseObject(Data(bodyText.utf8))
                } else {
                    nil
                }
                return ParsedMessage(obj: obj)
            }.value
            self?.handleMessage(
                obj: parsed.obj,
                isMainFrame: isMainFrame,
                scheme: scheme,
                host: host,
                port: port
            )
        }
    }

    /// 消息处理（主线程）：nonce 提取 → origin 授权 → 路由 → 回传。
    /// 与 `userContentController(_:didReceive:)` 分离：JSON 解析已在 detached 任务完成
    /// （见 review E-1）。
    private func handleMessage(
        obj: [String: Any]?,
        isMainFrame: Bool,
        scheme: String,
        host: String,
        port: Int
    ) {
        // best-effort：先取 nonce/id，保证后续失败路径也能带 nonce 回传。
        let nonce = (obj?["nonce"] as? String) ?? (obj?["id"] as? String) ?? ""

        // 安全边界（H1）：origin 一律按消息来源实时推导，绝不使用宿主设置的全局状态
        // （导航后可能过期/写错），页面 JS 也无法伪造 `frameInfo`。
        // - 只信任主 frame：`forMainFrameOnly` 只限制用户脚本注入，消息通道对 webview
        //   内**所有 frame** 开放——跨域 iframe（广告/内嵌页）里的任意 JS 都能直接
        //   `postMessage` 到 `_tw_`，这类消息视为伪造，直接丢弃（其 pending 由 JS 侧
        //   60s 超时兜底，且无法经主 frame 的 `_ccdaoSettle` 回传）。
        // - 主 frame origin 取自 `frameInfo.securityOrigin`（系统按当前文档推导）。
        guard
            let origin = Self.authorizedOrigin(
                isMainFrame: isMainFrame,
                scheme: scheme,
                host: host,
                port: port
            )
        else {
            // 仅当消息来自主 frame 且 origin 不合法（about:blank / file:// 等）时
            // 按既有契约回错误；子 frame 消息在上面的授权判定已被拒绝，不回传。
            if isMainFrame {
                self.deliver(NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: "Unsafe or missing origin"))
            }
            return
        }

        guard
            let obj,
            let name = obj["name"] as? String,
            let network = obj["network"] as? String,
            let id = obj["id"] as? String
        else {
            self.deliver(NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: "Malformed request"))
            return
        }

        let request = DAppRequest(
            name: name,
            network: network,
            id: id,
            nonce: obj["nonce"] as? String,
            params: obj["params"] as? [Any]
        )

        Task { @MainActor in
            let payload = await route(request, origin: origin)
            self.deliver(payload)
        }
    }

    /// 从消息来源推导可授权 origin（纯函数，便于单测；`WKScriptMessage` 无法在测试中构造）。
    ///
    /// - 仅主 frame：子 frame 消息一律拒绝（消息通道对所有 frame 开放）；
    /// - 仅 http/https 且 host 非空；
    /// - 结果经 `WebOrigin.normalize` 归一化（小写、去默认端口）。
    nonisolated static func authorizedOrigin(isMainFrame: Bool, scheme: String, host: String, port: Int) -> String? {
        guard isMainFrame else { return nil }
        let normalizedScheme = scheme.lowercased()
        guard normalizedScheme == "http" || normalizedScheme == "https" else { return nil }
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else { return nil }
        // WKSecurityOrigin.host 的 IPv6 地址不带方括号，URLComponents 解析需要补上。
        let urlHost = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        let url = port != 0 ? "\(normalizedScheme)://\(urlHost):\(port)" : "\(normalizedScheme)://\(urlHost)"
        return WebOrigin.normalize(url)
    }

    /// Native → JS 响应投递：evaluateJavaScript 调用 provider JS 的 `window._ccdaoSettle`。
    /// 说明：`WKScriptMessageHandlerWithReply` 的 reply 通道在裸测试进程（macOS/iOS 模拟器）
    /// 不送达；改为 legacy handler + evaluateJavaScript 回传（与 SwiftWebviewBridge 同款、
    /// 已验证可用的模式）。M1 加固：回传携带 `responseToken`，provider 闭包校验通过才
    /// settle——页面 JS 无 token 且读不到挂起 nonce，无法伪造 native 响应；入口函数本身
    /// 也被 provider 冻结（不可写/不可删）。
    private func deliver(_ payload: [String: Any]) {
        guard let webView else { return }
        let nonce = (payload["nonce"] as? String) ?? ""
        let json = payload.jsonString
        let script =
            "window._ccdaoSettle && window._ccdaoSettle(\(Json.jsStringLiteral(nonce)), \(Json.jsStringLiteral(json)), \(Json.jsStringLiteral(self.responseToken)));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - 路由（internal，供测试直接调用）

    // 按域拆分（review 命名规范 #8）：顶层 route 只按域分发，各域方法内做参数提取
    // 与 handler 调用（参数提取位置不变——用户评估后认为下沉到 handler 更啰嗦，见 P1#8）。

    func route(_ request: DAppRequest, origin: String) async -> [String: Any] {
        switch DAppMethod.fromValue(request.name) {
        case .swtcRequestAccounts, .swtcSendTransaction, .swtcMultiSign,
             .swtcSignMessage, .swtcGetPublicKey, .swtcRequestNfts:
            await self.routeSwtc(request, origin: origin)
        case .ethAccounts, .ethRequestAccounts, .ethChainId, .ethBlockNumber,
             .ethPersonalSign, .ethPersonalEcRecover, .ethSignTypedData,
             .ethSignTypedDataV3, .ethSignTypedDataV4, .ethSendTransaction,
             .ethSignTransaction, .ethGetEncryptionPublicKey, .ethDecrypt,
             .ethRequestNfts:
            await self.routeEth(request, origin: origin)
        case .walletSwitchEthereumChain:
            await self.routeWallet(request, origin: origin)
        case .didRequestAccountName, .didGetBase58PublicKey, .didIssueCredential,
             .ipfsPersonalSign, .ipfsGetPublicKey:
            await self.routeDidNft(request, origin: origin)
        case .web3ClientVersion:
            self.success(request.nonce ?? request.id, .string("CCDAO/v1.0.0"))
        case .unknown:
            self.error(request.nonce ?? request.id, "Method not supported")
        }
    }

    /// SWTC 域：requestAccounts / sendTransaction / multiSign / signMessage / publicKey / requestNfts。
    private func routeSwtc(_ request: DAppRequest, origin: String) async -> [String: Any] {
        let nonce = request.nonce ?? request.id
        switch DAppMethod.fromValue(request.name) {
        case .swtcRequestAccounts:
            return await self.handleSwtcRequestAccounts(nonce: nonce, origin: origin)
        case .swtcSendTransaction:
            guard let txParams = paramsObject(request.params, index: 0) else {
                return self.missingParams(nonce, "Missing transaction parameters")
            }
            return await self.handleSwtcSendTransaction(nonce: nonce, origin: origin, txParams: txParams)
        case .swtcMultiSign:
            guard let msParams = paramsObject(request.params, index: 0) else {
                return self.missingParams(nonce, "Missing multi-sign parameters")
            }
            return await self.handleSwtcMultiSign(nonce: nonce, origin: origin, msParams: msParams)
        case .swtcSignMessage:
            guard
                let from = paramsString(request.params, index: 0),
                let data = paramsString(request.params, index: 1)
            else {
                return self.missingParams(nonce, "Missing sign message parameters")
            }
            return await self.handleSwtcSignMessage(nonce: nonce, origin: origin, from: from, data: data)
        case .swtcGetPublicKey:
            guard let address = paramsString(request.params, index: 0) else {
                return self.missingParams(nonce, "Missing address parameter")
            }
            return await self.handleSwtcGetPublicKey(nonce: nonce, origin: origin, address: address)
        case .swtcRequestNfts:
            let address = self.paramsString(request.params, index: 0) ?? ""
            return await self.handleSwtcRequestNfts(nonce: nonce, address: address)
        default:
            return self.error(nonce, "Method not supported")
        }
    }

    /// ETH 域：EIP-1193 全部 + eth_requestNfts。
    private func routeEth(_ request: DAppRequest, origin: String) async -> [String: Any] {
        let nonce = request.nonce ?? request.id
        switch DAppMethod.fromValue(request.name) {
        case .ethRequestAccounts:
            return await self.handleEthRequestAccounts(nonce: nonce, origin: origin)
        case .ethAccounts:
            // EIP-1193：eth_accounts 静默返回已授权账户，不弹授权框（review P1#2）
            return await self.handleEthAccounts(nonce: nonce)
        case .ethChainId:
            return self.success(nonce, .string(self.ethMiddleware.chainId()))
        case .ethBlockNumber:
            return await self.handleEthBlockNumber(nonce: nonce)
        case .ethPersonalSign:
            guard
                let message = paramsString(request.params, index: 0),
                let address = paramsString(request.params, index: 1)
            else {
                return self.missingParams(nonce, "Missing personal_sign parameters")
            }
            return await self.handleEthPersonalSign(nonce: nonce, origin: origin, address: address, message: message)
        case .ethPersonalEcRecover:
            guard
                let message = paramsString(request.params, index: 0),
                let signature = paramsString(request.params, index: 1)
            else {
                return self.missingParams(nonce, "Missing personal_ecRecover parameters")
            }
            return await self.handleEthRecoverPersonalSignature(nonce: nonce, message: message, signature: signature)
        case .ethSignTypedData:
            return await self.handleEthSignTypedData(nonce: nonce, origin: origin, request: request, version: "V1")
        case .ethSignTypedDataV3:
            return await self.handleEthSignTypedData(nonce: nonce, origin: origin, request: request, version: "V3")
        case .ethSignTypedDataV4:
            return await self.handleEthSignTypedData(nonce: nonce, origin: origin, request: request, version: "V4")
        case .ethGetEncryptionPublicKey:
            guard let address = paramsString(request.params, index: 0) else {
                return self.missingParams(nonce, "Missing eth_getEncryptionPublicKey parameters")
            }
            return await self.handleEthGetEncryptionPublicKey(nonce: nonce, origin: origin, address: address)
        case .ethDecrypt:
            guard
                let message = paramsString(request.params, index: 0),
                let address = paramsString(request.params, index: 1)
            else {
                return self.missingParams(nonce, "Missing eth_decrypt parameters")
            }
            return await self.handleEthDecrypt(nonce: nonce, origin: origin, address: address, message: message)
        case .ethSignTransaction:
            guard let txParams = paramsObject(request.params, index: 0) else {
                return self.missingParams(nonce, "Missing transaction parameters")
            }
            return await self.handleEthSignTransaction(nonce: nonce, origin: origin, txParams: txParams)
        case .ethSendTransaction:
            guard let txParams = paramsObject(request.params, index: 0) else {
                return self.missingParams(nonce, "Missing transaction parameters")
            }
            return await self.handleEthSendTransaction(nonce: nonce, origin: origin, txParams: txParams)
        case .ethRequestNfts:
            let address = self.paramsString(request.params, index: 0) ?? ""
            let whiteList = self.paramsArray(request.params, index: 1)
            return await self.handleEthRequestNfts(nonce: nonce, address: address, whiteList: whiteList)
        default:
            return self.error(nonce, "Method not supported")
        }
    }

    /// Wallet 域：wallet_switchEthereumChain。
    private func routeWallet(_ request: DAppRequest, origin: String) async -> [String: Any] {
        let nonce = request.nonce ?? request.id
        guard let chainId = paramsObject(request.params, index: 0)?["chainId"] as? String else {
            return self.missingParams(nonce, "Missing chainId parameter")
        }
        return await self.handleWalletSwitchEthereumChain(nonce: nonce, origin: origin, chainId: chainId)
    }

    /// DID / IPFS 域：did_* / ipfs_*（与 NFT 相关方法一同按域拆分，命名 #8）。
    private func routeDidNft(_ request: DAppRequest, origin: String) async -> [String: Any] {
        let nonce = request.nonce ?? request.id
        switch DAppMethod.fromValue(request.name) {
        case .didRequestAccountName:
            let address = self.paramsString(request.params, index: 0) ?? ""
            return await self.handleDidRequestAccountName(nonce: nonce, address: address)
        case .didGetBase58PublicKey:
            let address = self.paramsString(request.params, index: 0) ?? ""
            return await self.handleDidGetBase58PublicKey(nonce: nonce, origin: origin, address: address)
        case .didIssueCredential:
            let vcJson = self.paramsObject(request.params, index: 0)
            return await self.handleDidIssueCredential(nonce: nonce, origin: origin, vcJson: vcJson)
        case .ipfsPersonalSign:
            let dataArray = self.paramsArray(request.params, index: 0)
            guard let address = paramsString(request.params, index: 1), dataArray != nil else {
                return self.missingParams(nonce, "Missing ipfs_personalSign parameters")
            }
            return await self.handleIpfsPersonalSign(nonce: nonce, origin: origin, address: address, data: dataArray ?? [])
        case .ipfsGetPublicKey:
            let address = self.paramsString(request.params, index: 0) ?? ""
            return await self.handleIpfsGetPublicKey(nonce: nonce, origin: origin, address: address)
        default:
            return self.error(nonce, "Method not supported")
        }
    }

    // MARK: - SWTC handlers

    private func handleSwtcRequestAccounts(nonce: String, origin: String) async -> [String: Any] {
        do {
            // review P1#1：SWTC 流程不再污染共享 ETH 链状态——原 `ethMiddleware.setCurrentChain(.swtc)`
            // 会让之后所有 ETH DApp 拿到 eth_chainId = 0x1（swtc 无 evmChainId 回退 1），且
            // eth_sendTransaction 无显式 chainId 时报 "Chain swtc does not have an EVM chainId"。
            // SWTC 账户走 swtcMiddleware（按 bip44Code == swtc 过滤），与 ethMiddleware 无关。
            let accounts = try await swtcMiddleware.requestAccounts(origin: origin)
            return self.success(nonce, .array(accounts))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleSwtcSendTransaction(nonce: String, origin: String, txParams: [String: Any]) async -> [String: Any] {
        do {
            let result = try await swtcMiddleware.sendTransaction(txParams: txParams, origin: origin)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleSwtcMultiSign(nonce: String, origin: String, msParams: [String: Any]) async -> [String: Any] {
        do {
            let result = try await swtcMiddleware.multiSign(msParams: msParams, origin: origin)
            return self.success(nonce, .object(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleSwtcSignMessage(nonce: String, origin: String, from: String, data: String) async -> [String: Any] {
        do {
            let result = try await swtcMiddleware.signMessage(from: from, data: data, origin: origin)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleSwtcGetPublicKey(nonce: String, origin: String, address: String) async -> [String: Any] {
        do {
            let result = try await swtcMiddleware.publicKey(address: address, origin: origin)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    // MARK: - ETH handlers

    private func handleEthRequestAccounts(nonce: String, origin: String) async -> [String: Any] {
        do {
            let accounts = try await ethMiddleware.requestAccounts(origin: origin)
            return self.success(nonce, .array(accounts))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthAccounts(nonce: String) async -> [String: Any] {
        do {
            let accounts = try await ethMiddleware.accounts()
            return self.success(nonce, .array(accounts))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthBlockNumber(nonce: String) async -> [String: Any] {
        do {
            let blockNumber = try await ethMiddleware.blockNumber()
            return self.success(nonce, .string(blockNumber))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthPersonalSign(nonce: String, origin: String, address: String, message: String) async -> [String: Any] {
        do {
            let result = try await ethMiddleware.personalSign(address: address, message: message, origin: origin)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthRecoverPersonalSignature(nonce: String, message: String, signature: String) async -> [String: Any] {
        do {
            let result = try await ethMiddleware.recoverPersonalSignature(message: message, signature: signature)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthSignTypedData(nonce: String, origin: String, request: DAppRequest, version: String) async -> [String: Any] {
        guard
            let address = paramsString(request.params, index: 0),
            let typedData = paramsString(request.params, index: 1)
        else {
            return self.missingParams(nonce, "Missing signTypedData parameters")
        }
        do {
            let result = try await ethMiddleware.signTypedData(
                address: address,
                typedData: typedData,
                version: version,
                origin: origin
            )
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthGetEncryptionPublicKey(nonce: String, origin: String, address: String) async -> [String: Any] {
        do {
            let result = try await ethMiddleware.encryptionPublicKey(address: address, origin: origin)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthDecrypt(nonce: String, origin: String, address: String, message: String) async -> [String: Any] {
        do {
            let result = try await ethMiddleware.decrypt(address: address, encryptedData: message, origin: origin)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthSignTransaction(nonce: String, origin: String, txParams: [String: Any]) async -> [String: Any] {
        do {
            let result = try await ethMiddleware.signTransaction(txParams: txParams, origin: origin)
            return self.success(nonce, .string(result.data))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthSendTransaction(nonce: String, origin: String, txParams: [String: Any]) async -> [String: Any] {
        do {
            let result = try await ethMiddleware.sendTransaction(txParams: txParams, origin: origin)
            return self.success(nonce, .string(result))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleWalletSwitchEthereumChain(nonce: String, origin: String, chainId: String) async -> [String: Any] {
        do {
            try await self.ethMiddleware.switchEthereumChain(chainIdHex: chainId, origin: origin)
            return self.success(nonce, .null)
        } catch {
            return self.failure(nonce, error)
        }
    }

    // MARK: - DID / IPFS

    private func handleDidRequestAccountName(nonce: String, address: String) async -> [String: Any] {
        let name = await accountProvider?.getAccountName(address) ?? ""
        return self.success(nonce, .string(name))
    }

    private func handleDidGetBase58PublicKey(nonce: String, origin: String, address: String) async -> [String: Any] {
        do {
            let didSDK = try requireDidSDK()
            let privateKey = try await privateKeyOrFail(address: address, origin: origin)
            let result = try await didSDK.didGenerateBase58PublicKey(privateKey: privateKey)
            return self.success(nonce, .object([
                "publicKeyBase58": result.publicKeyBase58,
                "type": result.type
            ]))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleDidIssueCredential(nonce: String, origin: String, vcJson: [String: Any]?) async -> [String: Any] {
        guard let vcJson else {
            return self.missingParams(nonce, "Missing VC JSON parameter")
        }
        do {
            let didSDK = try requireDidSDK()
            guard
                let keyDoc = vcJson["keyDoc"] as? [String: Any],
                let address = keyDoc["address"] as? String
            else {
                throw DAppConnectError.internalError("Missing keyDoc.address")
            }
            let privateKey = try await privateKeyOrFail(address: address, origin: origin)
            let signedVc = try await didSDK.signCredential(privateKey: privateKey, vcJson: vcJson.jsonString)
            if let object = Json.parseObject(Data(signedVc.utf8)) {
                return self.success(nonce, .object(object))
            }
            return self.success(nonce, .string(signedVc))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleIpfsPersonalSign(nonce: String, origin: String, address: String, data: [Any]) async -> [String: Any] {
        do {
            let didSDK = try requireDidSDK()
            let bytes = data.compactMap { $0 as? Int }
            guard bytes.count == data.count else {
                throw DAppConnectError.internalError("Invalid ipfs_personalSign data")
            }
            let privateKey = try await privateKeyOrFail(address: address, origin: origin)
            let signature = try await didSDK.ipfsPersonalSign(privateKey: privateKey, data: bytes)
            self.didDocumentMutationListener?()
            return self.success(nonce, .string(signature))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleIpfsGetPublicKey(nonce: String, origin: String, address: String) async -> [String: Any] {
        do {
            let didSDK = try requireDidSDK()
            let privateKey = try await privateKeyOrFail(address: address, origin: origin)
            let publicKey = try await didSDK.ipfsGetPublicKey(privateKey: privateKey)
            return self.success(nonce, .string(publicKey))
        } catch {
            return self.failure(nonce, error)
        }
    }

    // MARK: - NFT

    private func handleSwtcRequestNfts(nonce: String, address: String) async -> [String: Any] {
        guard let nftProvider else {
            return self.success(nonce, .object(self.emptyNftResult(address: address)))
        }
        do {
            let result = try await nftProvider.swtcNfts(address: address)
            return self.success(nonce, .object(self.swtcNftJson(result)))
        } catch {
            return self.failure(nonce, error)
        }
    }

    private func handleEthRequestNfts(nonce: String, address: String, whiteList: [Any]?) async -> [String: Any] {
        guard let nftProvider else {
            return self.success(nonce, .object(self.emptyNftResult(address: address)))
        }
        do {
            let chainIdHex = "0x" + (Int64(ethMiddleware.chainId().replacingOccurrences(of: "0x", with: ""), radix: 16)
                .map { String($0, radix: 16) } ?? "1")
            let result = try await nftProvider.evmNfts(address: address, chainIdHex: chainIdHex, whiteList: JsonArrayParams(whiteList))
            return self.success(nonce, .object(self.ethNftJson(result, defaultChainIdHex: chainIdHex)))
        } catch {
            return self.failure(nonce, error)
        }
    }

    // MARK: - helpers

    private func requireDidSDK() throws -> any DidSDK {
        guard let didSDK else {
            throw DAppConnectError.internalError("DidSDK not initialized")
        }
        return didSDK
    }

    private func privateKeyOrFail(address: String, origin: String) async throws -> String {
        guard let secretProvider else {
            throw DAppConnectError.internalError("SecretProvider not configured")
        }
        guard let key = try await secretProvider.getPrivateKeyForAddress(address, origin: origin) else {
            throw DAppConnectError.internalError("User cancelled or private key not available")
        }
        return key
    }

    private func paramsString(_ params: [Any]?, index: Int) -> String? {
        guard let params, params.indices.contains(index) else { return nil }
        return params[index] as? String
    }

    private func paramsObject(_ params: [Any]?, index: Int) -> [String: Any]? {
        guard let params, params.indices.contains(index) else { return nil }
        return params[index] as? [String: Any]
    }

    private func paramsArray(_ params: [Any]?, index: Int) -> [Any]? {
        guard let params, params.indices.contains(index) else { return nil }
        return params[index] as? [Any]
    }

    private func success(_ nonce: String, _ result: RPCResult?) -> [String: Any] {
        NativeResponseChannel.successPayload(nonce: nonce, result: result)
    }

    private func error(_ nonce: String, _ message: String) -> [String: Any] {
        NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: message)
    }

    /// 缺参/参数格式错误：EIP-1193 JSON-RPC 标准码 -32602（review P1#13——
    /// 原用 -1 与内部错误混淆）。
    private func missingParams(_ nonce: String, _ message: String) -> [String: Any] {
        NativeResponseChannel.errorPayload(nonce: nonce, code: DAppConnectError.invalidParams(message).jsonRpcCode, message: message)
    }

    /// 错误回传：`DAppConnectError` 按 EIP-1193 码 + 消息回传；其他错误**不透传
    /// `localizedDescription` 给页面**（可能泄漏内部路径/SQL/密钥上下文，review P1#13）——
    /// 页面拿到通用「内部错误」，细节记日志。
    private func failure(_ nonce: String, _ error: Error) -> [String: Any] {
        if let dappError = error as? DAppConnectError {
            return NativeResponseChannel.errorPayload(nonce: nonce, code: dappError.jsonRpcCode, message: dappError.message)
        }
        let nsError = error as NSError
        Self.logger.error("native error: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
        return NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: "Internal error")
    }

    private func emptyNftResult(address: String) -> [String: Any] {
        ["address": address, "total": 0, "nfts": []]
    }

    private func swtcNftJson(_ result: SwtcNftResult) -> [String: Any] {
        // 容量预分配（review F-2：逐条构建不可避免，预分配避免 rehash）
        var nfts: [[String: Any]] = []
        nfts.reserveCapacity(result.nfts.count)
        for item in result.nfts {
            var dict: [String: Any] = [:]
            dict.reserveCapacity(5)
            item.image.map { dict["image"] = $0 }
            item.issuer.map { dict["issuer"] = $0 }
            item.fundCodeName.map { dict["fundCodeName"] = $0 }
            item.tokenId.map { dict["tokenId"] = $0 }
            item.hash.map { dict["hash"] = $0 }
            nfts.append(dict)
        }
        return ["address": result.address, "total": result.total, "nfts": nfts]
    }

    private func ethNftJson(_ result: EvmNftResult, defaultChainIdHex: String) -> [String: Any] {
        // 容量预分配（review F-2）
        var groups: [[String: Any]] = []
        groups.reserveCapacity(result.nfts.count)
        for group in result.nfts {
            let firstToken = group.tokens.first
            var tokens: [[String: Any]] = []
            tokens.reserveCapacity(group.tokens.count)
            for token in group.tokens {
                var dict: [String: Any] = [
                    "tokenId": token.tokenId,
                    "name": token.name ?? "",
                    "description": "",
                    "image": token.imageUrl ?? ""
                ]
                dict["tokenURI"] = NSNull()
                tokens.append(dict)
            }
            var groupDict: [String: Any] = [
                "chainId": firstToken?.chainId ?? defaultChainIdHex,
                "contractAddress": group.contractAddress,
                "name": firstToken?.name ?? "",
                "symbol": NSNull(),
                "standard": "ERC721",
                "count": group.tokens.count
            ]
            groupDict["tokens"] = tokens
            groups.append(groupDict)
        }
        return ["address": result.address, "total": result.total, "nfts": groups]
    }
}

/// detached 任务解析结果包装：`[String: Any]` 非 Sendable，无法直接跨 actor；
/// JSONSerialization 产出不可变 NSDictionary/NSArray（只读），跨线程传递安全
/// （见 review E-1：解析移出主线程）。
private struct ParsedMessage: @unchecked Sendable {
    let obj: [String: Any]?
}
