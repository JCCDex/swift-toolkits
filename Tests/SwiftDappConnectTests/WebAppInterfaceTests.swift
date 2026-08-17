import Foundation
@testable import SwiftDappConnect
import Testing

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

@Test @MainActor func `eth request accounts routes to middleware with nonce`() async {
    let eth = FakeEthMiddleware()
    eth.requestAccountsResult = ["0x1"]
    let interface = makeInterface(eth: eth)

    let payload = await interface.route(request(name: "eth_requestAccounts"), origin: "https://dapp.com")

    #expect(payload["nonce"] as? String == "nonce-1")
    #expect(payload["result"] as? [String] == ["0x1"])
    #expect(eth.recordedOrigins == ["https://dapp.com"])
}

@Test @MainActor func `unknown method returns method not supported error`() async {
    let interface = makeInterface()
    let payload = await interface.route(request(name: "no_such_method"), origin: "https://dapp.com")

    #expect(payload["nonce"] as? String == "nonce-1")
    let error = payload["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -1)
    #expect(error?["message"] as? String == "Method not supported")
}

@Test @MainActor func `swtc request accounts flips eth chain to swtc`() async {
    let eth = FakeEthMiddleware()
    let swtc = FakeSwtcMiddleware()
    swtc.requestAccountsResult = ["j1"]
    let interface = makeInterface(eth: eth, swtc: swtc)

    let payload = await interface.route(request(name: "swtc_requestAccounts", network: "swtc"), origin: "https://dapp.com")

    #expect(payload["result"] as? [String] == ["j1"])
    #expect(eth.setCurrentChainCalls == [.swtc])
}

@Test @MainActor func `user rejected maps to error code 4001`() async {
    let eth = FakeEthMiddleware()
    eth.requestAccountsError = DAppConnectError.userRejected("User rejected")
    let interface = makeInterface(eth: eth)

    let payload = await interface.route(request(name: "eth_requestAccounts"), origin: "https://dapp.com")
    let error = payload["error"] as? [String: Any]
    #expect(error?["code"] as? Int == 4001)
}

@Test @MainActor func `web3 client version returns constant`() async {
    let interface = makeInterface()
    let payload = await interface.route(request(name: "web3_clientVersion"), origin: "https://dapp.com")
    #expect(payload["result"] as? String == "CCDAO/v1.0.0")
}

@Test @MainActor func `missing transaction params returns error`() async {
    let interface = makeInterface()
    let payload = await interface.route(request(name: "eth_sendTransaction"), origin: "https://dapp.com")
    let error = payload["error"] as? [String: Any]
    #expect(error?["message"] as? String == "Missing transaction parameters")
}

@Test @MainActor func `wallet switch chain success returns null result`() async {
    let eth = FakeEthMiddleware()
    let interface = makeInterface(eth: eth)

    let payload = await interface.route(
        request(name: "wallet_switchEthereumChain", params: [["chainId": "0x1"]]),
        origin: "https://dapp.com"
    )

    #expect(eth.chainSwitched)
    #expect(payload["result"] is NSNull)
}

// ── H1：消息来源 origin 推导（frameInfo 无法在单测构造，测试纯函数） ──

@Test func `authorized origin accepts main frame https and strips default port`() {
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "https", host: "DApp.Example.com", port: 443) == "https://dapp.example.com")
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "https", host: "dapp.example.com", port: 0) == "https://dapp.example.com")
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "http", host: "dapp.example.com", port: 80) == "http://dapp.example.com")
}

@Test func `authorized origin keeps non default port`() {
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "https", host: "dapp.example.com", port: 8443) == "https://dapp.example.com:8443")
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "http", host: "dapp.example.com", port: 8080) == "http://dapp.example.com:8080")
}

@Test func `authorized origin rejects sub frame messages`() {
    // iframe 消息通道对所有 frame 开放：子 frame 消息一律视为伪造。
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: false, scheme: "https", host: "evil.example.com", port: 443) == nil)
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: false, scheme: "https", host: "dapp.example.com", port: 443) == nil)
}

@Test func `authorized origin rejects non http schemes and empty hosts`() {
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "file", host: "x", port: 0) == nil)
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "about", host: "blank", port: 0) == nil)
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "https", host: "", port: 0) == nil)
    #expect(WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "", host: "dapp.example.com", port: 0) == nil)
}

@Test func `authorized origin accepts ipv6 host`() {
    let origin = WebAppInterface.authorizedOrigin(isMainFrame: true, scheme: "https", host: "::1", port: 8443)
    #expect(origin != nil)
    #expect(origin?.contains("::1") == true)
    // 输出必须能被再次归一化（round-trip 稳定，无悬挂的非法格式）。
    #expect(WebOrigin.normalize(origin ?? "") == origin)
}

// ── M1/M2：responseToken 生成与便捷 JS 构建器 ──

@Test @MainActor func `response token is unique per interface`() {
    let first = makeInterface()
    let second = makeInterface()

    #expect(!first.responseToken.isEmpty)
    #expect(!second.responseToken.isEmpty)
    #expect(first.responseToken.count == 64) // 32 字节 hex
    #expect(first.responseToken != second.responseToken)
}

@Test @MainActor func `instance js builders embed the response token`() {
    let interface = makeInterface()
    let token = interface.responseToken

    #expect(interface.loadInitJs(chainIdHex: "0x38", rpcUrl: "https://rpc.example.com").contains("\"\(token)\""))
    #expect(interface.loadAddressJs(address: "0xabc", isSwtc: false).contains("\"\(token)\""))
    #expect(interface.loadUpdateChainIdJs(chainIdHex: "0x1", rpcUrl: "https://rpc.example.com").contains("\"\(token)\""))
}
