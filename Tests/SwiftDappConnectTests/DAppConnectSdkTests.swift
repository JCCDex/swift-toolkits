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

@Test func `load address js uses evm and swtc updaters`() {
    let evm = DAppConnectSdk.loadAddressJs(address: "0xabc", isSwtc: false)
    #expect(evm.contains("_updateSelectedAddress"))
    #expect(evm.contains("\"0xabc\""))

    let swtc = DAppConnectSdk.loadAddressJs(address: "abc", isSwtc: true)
    #expect(swtc.contains("_updateSwtcSelectedAddress"))
}

@Test func `load init js embeds chain id and rpc url`() {
    let js = DAppConnectSdk.loadInitJs(chainIdHex: "0x38", rpcUrl: "https://rpc.example.com")
    #expect(js.contains("0x38"))
    #expect(js.contains("https://rpc.example.com"))
    #expect(js.contains("_ccdaoProviderState"))
}

@Test func `load update chain id js uses global updater`() {
    let js = DAppConnectSdk.loadUpdateChainIdJs(chainIdHex: "0x1", rpcUrl: "https://rpc.example.com")
    #expect(js.contains("_updateChainId"))
}

@Test func `load eip6963 icon override embeds data uri`() {
    let js = DAppConnectSdk.loadEip6963IconOverrideJs(iconDataUri: "data:image/png;base64,AAAA")
    #expect(js.contains("data:image/png;base64,AAAA"))
    #expect(js.contains("eip6963:announceProvider"))
}

@Test func `provider js resource is bundled`() {
    #expect(!DAppConnectSdk.loadProviderJs().isEmpty)
    #expect(DAppConnectSdk.loadProviderJs().contains("window.ethereum"))
}

@Test func `adapter script wires _tw_ to message handlers`() {
    #expect(DAppConnectSdk.adapterScript.contains("messageHandlers._tw_"))
}
