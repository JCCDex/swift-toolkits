import Foundation
@testable import SwiftDappConnect
import Testing

@Test func `dapp method parses known method names`() {
    #expect(DAppMethod.fromValue("swtc_requestAccounts") == .swtcRequestAccounts)
    #expect(DAppMethod.fromValue("eth_requestAccounts") == .ethRequestAccounts)
    #expect(DAppMethod.fromValue("eth_accounts") == .ethAccounts)
    #expect(DAppMethod.fromValue("personal_sign") == .ethPersonalSign)
    #expect(DAppMethod.fromValue("eth_signTypedData_v4") == .ethSignTypedDataV4)
    #expect(DAppMethod.fromValue("wallet_switchEthereumChain") == .walletSwitchEthereumChain)
    #expect(DAppMethod.fromValue("did_issueCredential") == .didIssueCredential)
    #expect(DAppMethod.fromValue("ipfs_personalSign") == .ipfsPersonalSign)
    #expect(DAppMethod.fromValue("web3_clientVersion") == .web3ClientVersion)
}

@Test func `dapp method unknown falls back to unknown`() {
    #expect(DAppMethod.fromValue("no_such_method") == .unknown)
}
