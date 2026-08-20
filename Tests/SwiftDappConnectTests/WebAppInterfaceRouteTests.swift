import Foundation
@testable import SwiftDappConnect
import Testing

/// WebAppInterface.route 全分支补测（对 WebAppInterfaceTests 的补充）：
/// ETH/SWTC 方法转发、参数缺失错误、错误码映射（4001/4902/-1）、NFT/DID 未配置路径、
/// NativeResponseChannel payload 构造。
@MainActor
private func makeInterface(
    eth: FakeEthMiddleware = FakeEthMiddleware(),
    swtc: FakeSwtcMiddleware = FakeSwtcMiddleware()
) -> WebAppInterface {
    WebAppInterface(ethMiddleware: eth, swtcMiddleware: swtc)
}

private func request(
    name: String,
    network: String = "eth",
    id: String = "1",
    nonce: String = "nonce-1",
    params: [Any]? = nil
) -> DAppRequest {
    DAppRequest(name: name, network: network, id: id, nonce: nonce, params: params)
}

@MainActor struct WebAppInterfaceRouteTests {
    @Test func `eth chain id and block number return constants`() async {
        let interface = makeInterface()
        let chainPayload = await interface.route(request(name: "eth_chainId"), origin: "https://dapp.com")
        #expect(chainPayload["nonce"] as? String == "nonce-1")
        #expect(chainPayload["result"] as? String == "0x38")

        let blockPayload = await interface.route(request(name: "eth_blockNumber"), origin: "https://dapp.com")
        #expect(blockPayload["result"] as? String == "0x1")
    }

    @Test func `eth sign transaction missing params returns error`() async {
        let interface = makeInterface()
        let payload = await interface.route(request(name: "eth_signTransaction"), origin: "https://dapp.com")
        let error = payload["error"] as? [String: Any]
        #expect(error?["message"] as? String == "Missing transaction parameters")
    }

    @Test func `eth sign transaction returns signed data`() async {
        let interface = makeInterface()
        let payload = await interface.route(
            request(name: "eth_signTransaction", params: [["from": "0x1", "to": "0x2", "value": "0x0"]]),
            origin: "https://dapp.com"
        )
        #expect(payload["result"] as? String == "0xsigned")
        #expect(payload["error"] == nil)
    }

    @Test func `eth personal sign and ec recover route`() async {
        let interface = makeInterface()
        let signPayload = await interface.route(
            request(name: "personal_sign", params: ["hello", "0x1"]),
            origin: "https://dapp.com"
        )
        #expect(signPayload["result"] as? String == "0xsig")

        let recoverPayload = await interface.route(
            request(name: "personal_ecRecover", params: ["hello", "0xsig"]),
            origin: "https://dapp.com"
        )
        #expect(recoverPayload["result"] as? String == "0xaddr")
    }

    @Test func `eth sign typed data v4 routes`() async {
        let interface = makeInterface()
        let payload = await interface.route(
            request(name: "eth_signTypedData_v4", params: ["0x1", #"{"types":{}}"#]),
            origin: "https://dapp.com"
        )
        #expect(payload["result"] as? String == "0xtyped")
    }

    @Test func `eth get encryption public key and decrypt route`() async {
        let interface = makeInterface()
        let pub = await interface.route(request(name: "eth_getEncryptionPublicKey", params: ["0x1"]), origin: "https://dapp.com")
        #expect(pub["result"] as? String == "0xpub")

        let decrypted = await interface.route(
            request(name: "eth_decrypt", params: ["cipher", "0x1"]),
            origin: "https://dapp.com"
        )
        #expect(decrypted["result"] as? String == "plaintext")
    }

    @Test func `swtc methods route with params`() async {
        let interface = makeInterface()

        let missingTx = await interface.route(request(name: "swtc_sendTransaction", network: "swtc"), origin: "https://dapp.com")
        let missingError = missingTx["error"] as? [String: Any]
        #expect(missingError?["message"] as? String == "Missing transaction parameters")

        let send = await interface.route(
            request(name: "swtc_sendTransaction", network: "swtc", params: [["from": "j1", "to": "j2"]]),
            origin: "https://dapp.com"
        )
        #expect(send["result"] as? String == "0xblobhash")

        let multi = await interface.route(
            request(name: "swtc_multiSign", network: "swtc", params: [["from": "j1"]]),
            origin: "https://dapp.com"
        )
        #expect(multi["error"] == nil)

        let signMessage = await interface.route(
            request(name: "swtc_signMessage", network: "swtc", params: ["j1", "0xdata"]),
            origin: "https://dapp.com"
        )
        #expect(signMessage["result"] as? String == "0xsig")

        let pubkey = await interface.route(
            request(name: "swtc_getPublicKey", network: "swtc", params: ["j1"]),
            origin: "https://dapp.com"
        )
        #expect(pubkey["result"] as? String == "0xpub")
    }

    @Test func `wallet switch chain missing chainId returns error`() async {
        let interface = makeInterface()
        let payload = await interface.route(request(name: "wallet_switchEthereumChain"), origin: "https://dapp.com")
        let error = payload["error"] as? [String: Any]
        #expect(error?["message"] as? String == "Missing chainId parameter")
    }

    @Test func `wallet switch unsupported chain maps to 4902`() async {
        let eth = FakeEthMiddleware()
        eth.switchError = DAppConnectError.chainNotSupported(chainId: 0x99999)
        let interface = makeInterface(eth: eth)

        let payload = await interface.route(
            request(name: "wallet_switchEthereumChain", params: [["chainId": "0x99999"]]),
            origin: "https://dapp.com"
        )
        let error = payload["error"] as? [String: Any]
        #expect(error?["code"] as? Int == 4902)
    }

    @Test func `nft requests return empty structure when provider missing`() async {
        let interface = makeInterface()
        let swtcPayload = await interface.route(request(name: "swtc_requestNfts", network: "swtc", params: ["j1"]), origin: "https://dapp.com")
        let swtcResult = swtcPayload["result"] as? [String: Any]
        #expect(swtcResult?["address"] as? String == "j1")
        #expect(swtcResult?["total"] as? Int == 0)
        #expect((swtcResult?["nfts"] as? [Any])?.isEmpty == true)

        let ethPayload = await interface.route(request(name: "eth_requestNfts", params: ["0x1"]), origin: "https://dapp.com")
        let ethResult = ethPayload["result"] as? [String: Any]
        #expect(ethResult?["address"] as? String == "0x1")
        #expect(ethResult?["total"] as? Int == 0)
    }

    @Test func `did get base58 public key fails without did sdk`() async {
        let interface = makeInterface()
        let payload = await interface.route(request(name: "did_getBase58PublicKey", params: ["0x1"]), origin: "https://dapp.com")
        #expect(payload["error"] != nil, "未配置 DidSDK → 失败而非静默返回")
    }

    @Test func `ipfs personal sign missing params returns error`() async {
        let interface = makeInterface()
        let payload = await interface.route(request(name: "ipfs_personalSign"), origin: "https://dapp.com")
        let error = payload["error"] as? [String: Any]
        #expect(error?["message"] as? String == "Missing ipfs_personalSign parameters")
    }

    @Test func `did request account name returns empty when provider missing`() async {
        let interface = makeInterface()
        let payload = await interface.route(request(name: "did_requestAccountName", params: ["0x1"]), origin: "https://dapp.com")
        #expect(payload["result"] as? String == "")
    }

    // ── NativeResponseChannel ──

    @Test func `native response channel builds success and error payloads`() {
        let success = NativeResponseChannel.successPayload(nonce: "n1", result: .string("ok"))
        #expect(success["nonce"] as? String == "n1")
        #expect(success["result"] as? String == "ok")

        let nullResult = NativeResponseChannel.successPayload(nonce: "n2", result: nil)
        #expect(nullResult["result"] is NSNull)

        let error = NativeResponseChannel.errorPayload(nonce: "n3", code: 4001, message: "User rejected")
        #expect(error["nonce"] as? String == "n3")
        let errorDict = error["error"] as? [String: Any]
        #expect(errorDict?["code"] as? Int == 4001)
        #expect(errorDict?["message"] as? String == "User rejected")
    }

    @Test func `json string serialization helper`() {
        let payload: [String: Any] = ["nonce": "n1", "result": ["a": 1]]
        #expect(payload.jsonString.contains("\"nonce\":\"n1\""))
        #expect(payload.jsonString.contains("\"a\":1"))
    }
}
