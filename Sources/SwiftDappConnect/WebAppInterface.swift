import Foundation
import WebKit

/// `_tw_` 接收端：把 DApp 的 postMessage 路由到对应中间件，并经 reply 通道回传。
@MainActor
public final class WebAppInterface: NSObject, WKScriptMessageHandler {
    public static let handlerName = "_tw_"

    private let ethMiddleware: any EthMiddlewareProtocol
    private let swtcMiddleware: any SwtcMiddlewareProtocol
    private let accountProvider: (any AccountProvider)?
    private let secretProvider: (any SecretProvider)?
    private let nftProvider: (any NftProvider)?
    private let didSDK: (any DidSDK)?
    private let didDocumentMutationListener: DidDocumentMutationListener?

    weak var webView: WKWebView?
    private var dappOrigin = ""
    private var chainProvider: (any ChainProvider)?
    private var onAccountSwitched: ((String) -> Void)?

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
        super.init()
    }

    /// 宿主必须在导航时设置 origin（M-05）；空白/非安全 origin 会被拒绝。
    public func setOrigin(_ origin: String) {
        self.dappOrigin = WebOrigin.normalize(origin) ?? origin.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let json = message.body as? String else {
            // body 非字符串：无法取得 nonce，靠 JS 侧 queue 超时兜底（见设计文档 03 章）
            return
        }

        // best-effort 解析：先取 nonce/id，保证后续失败路径也能带 nonce 回传。
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let nonce = (obj?["nonce"] as? String) ?? (obj?["id"] as? String) ?? ""

        let origin = self.dappOrigin
        guard !origin.isEmpty, DAppConnectSdk.isSafeUrl(origin) else {
            self.deliver(NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: "Unsafe or missing origin"))
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

    /// Native → JS 响应投递：evaluateJavaScript 调用 provider JS 的 `window._ccdaoSettle`。
    /// 说明：`WKScriptMessageHandlerWithReply` 的 reply 通道在裸测试进程（macOS/iOS 模拟器）
    /// 不送达；改为 legacy handler + evaluateJavaScript 回传（与 SwiftWebviewBridge 同款、
    /// 已验证可用的模式）。页面内伪造 settle 只能影响其自身请求，安全性等价。
    private func deliver(_ payload: [String: Any]) {
        guard let webView else { return }
        let nonce = (payload["nonce"] as? String) ?? ""
        let json = payload.jsonString
        let script =
            "window._ccdaoSettle && window._ccdaoSettle(\(Self.jsQuote(nonce)), \(Self.jsQuote(json)));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func jsQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    // MARK: - 路由（internal，供测试直接调用）

    func route(_ request: DAppRequest, origin: String) async -> [String: Any] {
        let nonce = request.nonce ?? request.id

        switch DAppMethod.fromValue(request.name) {
        // SWTC
        case .swtcRequestAccounts:
            return await self.handleSwtcRequestAccounts(nonce: nonce, origin: origin)
        case .swtcSendTransaction:
            guard let txParams = paramsObject(request.params, index: 0) else {
                return self.error(nonce, "Missing transaction parameters")
            }
            return await self.handleSwtcSendTransaction(nonce: nonce, origin: origin, txParams: txParams)
        case .swtcMultiSign:
            guard let msParams = paramsObject(request.params, index: 0) else {
                return self.error(nonce, "Missing multi-sign parameters")
            }
            return await self.handleSwtcMultiSign(nonce: nonce, origin: origin, msParams: msParams)
        case .swtcSignMessage:
            guard
                let from = paramsString(request.params, index: 0),
                let data = paramsString(request.params, index: 1)
            else {
                return self.error(nonce, "Missing sign message parameters")
            }
            return await self.handleSwtcSignMessage(nonce: nonce, origin: origin, from: from, data: data)
        case .swtcGetPublicKey:
            guard let address = paramsString(request.params, index: 0) else {
                return self.error(nonce, "Missing address parameter")
            }
            return await self.handleSwtcGetPublicKey(nonce: nonce, origin: origin, address: address)
        // ETH
        case .ethRequestAccounts, .ethAccounts:
            return await self.handleEthRequestAccounts(nonce: nonce, origin: origin)
        case .ethChainId:
            return self.success(nonce, .string(self.ethMiddleware.getChainId()))
        case .ethBlockNumber:
            return await self.handleEthBlockNumber(nonce: nonce)
        case .ethPersonalSign:
            guard
                let message = paramsString(request.params, index: 0),
                let address = paramsString(request.params, index: 1)
            else {
                return self.error(nonce, "Missing personal_sign parameters")
            }
            return await self.handleEthPersonalSign(nonce: nonce, origin: origin, address: address, message: message)
        case .ethPersonalEcRecover:
            guard
                let message = paramsString(request.params, index: 0),
                let signature = paramsString(request.params, index: 1)
            else {
                return self.error(nonce, "Missing personal_ecRecover parameters")
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
                return self.error(nonce, "Missing eth_getEncryptionPublicKey parameters")
            }
            return await self.handleEthGetEncryptionPublicKey(nonce: nonce, origin: origin, address: address)
        case .ethDecrypt:
            guard
                let message = paramsString(request.params, index: 0),
                let address = paramsString(request.params, index: 1)
            else {
                return self.error(nonce, "Missing eth_decrypt parameters")
            }
            return await self.handleEthDecrypt(nonce: nonce, origin: origin, address: address, message: message)
        case .ethSignTransaction:
            guard let txParams = paramsObject(request.params, index: 0) else {
                return self.error(nonce, "Missing transaction parameters")
            }
            return await self.handleEthSignTransaction(nonce: nonce, origin: origin, txParams: txParams)
        case .ethSendTransaction:
            guard let txParams = paramsObject(request.params, index: 0) else {
                return self.error(nonce, "Missing transaction parameters")
            }
            return await self.handleEthSendTransaction(nonce: nonce, origin: origin, txParams: txParams)
        // Wallet
        case .walletSwitchEthereumChain:
            guard let chainId = paramsObject(request.params, index: 0)?["chainId"] as? String else {
                return self.error(nonce, "Missing chainId parameter")
            }
            return await self.handleWalletSwitchEthereumChain(nonce: nonce, origin: origin, chainId: chainId)
        // SWTC / ETH NFT
        case .swtcRequestNfts:
            let address = self.paramsString(request.params, index: 0) ?? ""
            return await self.handleSwtcRequestNfts(nonce: nonce, address: address)
        case .ethRequestNfts:
            let address = self.paramsString(request.params, index: 0) ?? ""
            let whiteList = self.paramsArray(request.params, index: 1)
            return await self.handleEthRequestNfts(nonce: nonce, address: address, whiteList: whiteList)
        // DID / IPFS
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
                return self.error(nonce, "Missing ipfs_personalSign parameters")
            }
            return await self.handleIpfsPersonalSign(nonce: nonce, origin: origin, address: address, data: dataArray ?? [])
        case .ipfsGetPublicKey:
            let address = self.paramsString(request.params, index: 0) ?? ""
            return await self.handleIpfsGetPublicKey(nonce: nonce, origin: origin, address: address)
        // Common
        case .web3ClientVersion:
            return self.success(nonce, .string("CCDAO/v1.0.0"))
        case .unknown:
            return self.error(nonce, "Method not supported")
        }
    }

    // MARK: - SWTC handlers

    private func handleSwtcRequestAccounts(nonce: String, origin: String) async -> [String: Any] {
        do {
            if self.ethMiddleware.currentChain != .swtc {
                self.ethMiddleware.setCurrentChain(.swtc)
            }
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
            let result = try await swtcMiddleware.getPublicKey(address: address, origin: origin)
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

    private func handleEthBlockNumber(nonce: String) async -> [String: Any] {
        do {
            let blockNumber = try await ethMiddleware.getBlockNumber()
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
            return self.error(nonce, "Missing signTypedData parameters")
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
            let result = try await ethMiddleware.getEncryptionPublicKey(address: address, origin: origin)
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
            let privateKey = try await getPrivateKeyOrFail(address: address, origin: origin)
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
            return self.error(nonce, "Missing VC JSON parameter")
        }
        do {
            let didSDK = try requireDidSDK()
            guard
                let keyDoc = vcJson["keyDoc"] as? [String: Any],
                let address = keyDoc["address"] as? String
            else {
                throw DAppConnectError.internalError("Missing keyDoc.address")
            }
            let privateKey = try await getPrivateKeyOrFail(address: address, origin: origin)
            let signedVc = try await didSDK.signCredentialForDApp(privateKey: privateKey, vcJson: vcJson.jsonString)
            if let object = (try? JSONSerialization.jsonObject(with: Data(signedVc.utf8))) as? [String: Any] {
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
            let privateKey = try await getPrivateKeyOrFail(address: address, origin: origin)
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
            let privateKey = try await getPrivateKeyOrFail(address: address, origin: origin)
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
            let result = try await nftProvider.getSwtcNfts(address: address)
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
            let chainIdHex = "0x" + (Int64(ethMiddleware.getChainId().replacingOccurrences(of: "0x", with: ""), radix: 16)
                .map { String($0, radix: 16) } ?? "1")
            let result = try await nftProvider.getEvmNfts(address: address, chainIdHex: chainIdHex, whiteList: whiteList)
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

    private func getPrivateKeyOrFail(address: String, origin: String) async throws -> String {
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

    private func failure(_ nonce: String, _ error: Error) -> [String: Any] {
        if let dappError = error as? DAppConnectError {
            return NativeResponseChannel.errorPayload(nonce: nonce, code: dappError.jsonRpcCode, message: dappError.message)
        }
        return NativeResponseChannel.errorPayload(nonce: nonce, code: -1, message: error.localizedDescription)
    }

    private func emptyNftResult(address: String) -> [String: Any] {
        ["address": address, "total": 0, "nfts": []]
    }

    private func swtcNftJson(_ result: SwtcNftResult) -> [String: Any] {
        var nfts: [[String: Any]] = []
        for item in result.nfts {
            var dict: [String: Any] = [:]
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
        var groups: [[String: Any]] = []
        for group in result.nfts {
            let firstToken = group.tokens.first
            var tokens: [[String: Any]] = []
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
