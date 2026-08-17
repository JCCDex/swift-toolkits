import Foundation
@testable import SwiftDappConnect
import Testing

@Test func `is safe url accepts valid urls`() {
    #expect(DAppConnectSdk.isSafeUrl("https://dapp.example.com"))
    #expect(DAppConnectSdk.isSafeUrl("http://dapp.example.com"))
    #expect(DAppConnectSdk.isSafeUrl("https://dapp.example.com:8443"))
    #expect(DAppConnectSdk.isSafeUrl("https://dapp.example.com/path?q=1"))
    #expect(DAppConnectSdk.isSafeUrl("https://dapp.jccdex.cn"))
}

@Test func `is safe url rejects unsafe urls`() {
    #expect(!DAppConnectSdk.isSafeUrl("file:///etc/passwd"))
    #expect(!DAppConnectSdk.isSafeUrl("javascript:alert(1)"))
    #expect(!DAppConnectSdk.isSafeUrl(""))
    #expect(!DAppConnectSdk.isSafeUrl("https://localhost")) // 无点单标签主机：两边都拒
    #expect(!DAppConnectSdk.isSafeUrl("rtsp://example.com/stream")) // Swift 比 Kotlin WEB_URL 更严
}

@Test func `load address js uses gated native dispatcher`() {
    let token = "tok-123"
    let evm = DAppConnectSdk.loadAddressJs(address: "0xabc", isSwtc: false, token: token)
    #expect(evm.contains("_ccdaoNative"))
    #expect(evm.contains("'setAddress'"))
    #expect(evm.contains("\"0xabc\""))
    #expect(evm.contains("isSwtc: false"))
    #expect(evm.contains("\"tok-123\""))

    let swtc = DAppConnectSdk.loadAddressJs(address: "abc", isSwtc: true, token: token)
    #expect(swtc.contains("isSwtc: true"))
}

@Test func `load init js embeds chain id and rpc url`() {
    let js = DAppConnectSdk.loadInitJs(chainIdHex: "0x38", rpcUrl: "https://rpc.example.com", token: "tok-1")
    #expect(js.contains("_ccdaoNative"))
    #expect(js.contains("'init'"))
    #expect(js.contains("0x38"))
    #expect(js.contains("https://rpc.example.com"))
    #expect(js.contains("\"tok-1\""))
    #expect(!js.contains("_ccdaoProviderState"))
}

@Test func `load update chain id js uses gated native dispatcher`() {
    let js = DAppConnectSdk.loadUpdateChainIdJs(chainIdHex: "0x1", rpcUrl: "https://rpc.example.com", token: "tok-1")
    #expect(js.contains("_ccdaoNative"))
    #expect(js.contains("'setChainId'"))
    #expect(js.contains("\"tok-1\""))
}

@Test func `load eip6963 icon override embeds data uri`() {
    let js = DAppConnectSdk.loadEip6963IconOverrideJs(iconDataUri: "data:image/png;base64,AAAA")
    #expect(js.contains("data:image/png;base64,AAAA"))
    #expect(js.contains("eip6963:announceProvider"))
}

@Test func `provider js resource is bundled and embeds token`() {
    let token = "deadbeefcafe0123456789abcdef0123"
    let js = DAppConnectSdk.loadProviderJs(token: token)
    #expect(!js.isEmpty)
    #expect(js.contains("window.ethereum"))
    // token 注入闭包（替换占位符），且原始占位符不再残留
    #expect(js.contains("\"deadbeefcafe0123456789abcdef0123\""))
    #expect(!js.contains("/*__CCDAO_BRIDGE_TOKEN__*/ null"))
    // M1/M2：状态收进闭包，回传入口带 token 校验并冻结
    #expect(js.contains("_ccdaoSettle"))
    #expect(js.contains("_ccdaoNative"))
    #expect(js.contains("writable: false"))
    // 不再有可写的全局状态对象（注释里提到名字不算）
    #expect(!js.contains("_ccdaoProviderState ="))
}

@Test func `adapter script wires _tw_ to message handlers`() {
    #expect(DAppConnectSdk.adapterScript.contains("messageHandlers._tw_"))
}
