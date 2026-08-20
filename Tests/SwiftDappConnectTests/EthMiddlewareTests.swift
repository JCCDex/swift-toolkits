import Foundation
import SwiftCore
@testable import SwiftDappConnect
import Testing

@MainActor
private func makeEthMiddleware(
    accounts: [WalletAccount] = [],
    secretProvider: any SecretProvider = FakeSecretProvider(privateKey: "pk"),
    chainProvider: (any ChainProvider)? = nil,
    currentChain: ChainType = .bsc
) -> EthMiddleware {
    EthMiddleware(
        accountProvider: FakeAccountProvider(accounts: accounts),
        secretProvider: secretProvider,
        nodeProvider: FakeNodeProvider(),
        chainProvider: chainProvider,
        initialChain: currentChain,
        signing: FakeWalletSigning()
    )
}

@Test @MainActor func `eth request accounts throws when no callback set`() async throws {
    let middleware = makeEthMiddleware(accounts: [makeAccount(address: "0x1")])
    await #expect(throws: DAppConnectError.userRejected("RequestAccountsCallback is not set")) {
        try await middleware.requestAccounts(origin: "https://dapp.com")
    }
}

@Test @MainActor func `eth request accounts returns filtered accounts when approved`() async throws {
    let accounts = [
        makeAccount(address: "0xa", chain: .bsc),
        makeAccount(address: "0xb", chain: .bsc, isHD: true, parentId: nil), // HD 根，排除
        makeAccount(address: "0xc", chain: .bsc, isHD: true, parentId: "root"), // HD 子账户，保留
        makeAccount(address: "0xd", chain: .eth) // 其它链，排除
    ]
    let middleware = makeEthMiddleware(accounts: accounts)
    var receivedOrigin: String?
    middleware.setRequestAccountsCallback { origin in
        receivedOrigin = origin
        return true
    }

    let result = try await middleware.requestAccounts(origin: "https://dapp.com")
    #expect(result == ["0xa", "0xc"])
    #expect(receivedOrigin == "https://dapp.com")
}

@Test @MainActor func `eth request accounts rejects when callback rejects`() async throws {
    let middleware = makeEthMiddleware(accounts: [makeAccount(address: "0x1")])
    middleware.setRequestAccountsCallback { _ in false }
    await #expect(throws: DAppConnectError.userRejected("User rejected the requestAccounts request")) {
        try await middleware.requestAccounts(origin: "https://dapp.com")
    }
}

@Test @MainActor func `eth personal sign passes origin to secret provider`() async throws {
    let recorder = SecretRecorder()
    let middleware = makeEthMiddleware(
        accounts: [makeAccount(address: "0xABC")],
        secretProvider: FakeSecretProvider(privateKey: "pk", recorder: recorder)
    )

    let signature = try await middleware.personalSign(address: "0xabc", message: "hello", origin: "https://dapp.com")
    #expect(signature == "0xsig")
    let calls = await recorder.privateKeyCalls
    #expect(calls.count == 1)
    #expect(calls[0].address == "0xabc")
    #expect(calls[0].origin == "https://dapp.com")
}

@Test @MainActor func `eth sign transaction fills chain id and signs`() async throws {
    let middleware = makeEthMiddleware(accounts: [makeAccount(address: "0xabc")])
    let result = try await middleware.signTransaction(
        txParams: ["from": "0xABC", "to": "0xdef", "value": "0x0"],
        origin: "https://dapp.com"
    )
    #expect(result.data == "0xsigned")
    #expect(result.chain == .bsc)
}

@Test @MainActor func `eth sign transaction rejects blank origin`() async throws {
    let middleware = makeEthMiddleware(accounts: [makeAccount(address: "0xabc")])
    await #expect(throws: DAppConnectError.internalError("origin must not be blank for signTransaction")) {
        _ = try await middleware.signTransaction(txParams: ["from": "0xabc"], origin: " ")
    }
}

@Test @MainActor func `eth send transaction returns broadcast hash`() async throws {
    let middleware = makeEthMiddleware(accounts: [makeAccount(address: "0xabc")])
    let hash = try await middleware.sendTransaction(
        txParams: ["from": "0xabc"],
        origin: "https://dapp.com"
    )
    #expect(hash == "0xhash")
}

@Test @MainActor func `switch chain to same chain returns immediately`() async throws {
    let middleware = makeEthMiddleware(currentChain: .bsc)
    try await middleware.switchEthereumChain(chainIdHex: "0x38", origin: "https://dapp.com")
    #expect(middleware.currentChain == .bsc)
}

@Test @MainActor func `switch chain to unsupported chain throws 4902`() async throws {
    let middleware = makeEthMiddleware(chainProvider: FakeChainProvider(supportedChains: [.bsc], currentChain: .bsc))
    await #expect(throws: DAppConnectError.chainNotSupported(chainId: 999)) {
        try await middleware.switchEthereumChain(chainIdHex: "0x3E7", origin: "https://dapp.com")
    }
}

@Test @MainActor func `switch chain rejected by user throws 4001`() async throws {
    let middleware = makeEthMiddleware(
        chainProvider: FakeChainProvider(
            supportedChains: [.bsc, .eth],
            currentChain: .bsc,
            confirm: { _, _, _ in false }
        )
    )
    await #expect(throws: DAppConnectError.userRejected("User rejected the chain switch request")) {
        try await middleware.switchEthereumChain(chainIdHex: "0x1", origin: "https://dapp.com")
    }
}

@Test @MainActor func `switch chain switches account and notifies`() async throws {
    let bscAccount = makeAccount(address: "0xSAME")
    let ethAccount = makeAccount(address: "0xSAME", chain: .eth)
    let middleware = makeEthMiddleware(
        accounts: [bscAccount, ethAccount],
        chainProvider: FakeChainProvider(supportedChains: [.bsc, .eth], currentChain: .bsc),
        currentChain: .bsc
    )
    var switchedAddress: String?
    middleware.setOnAccountSwitched { switchedAddress = $0 }

    try await middleware.switchEthereumChain(chainIdHex: "0x1", origin: "https://dapp.com")

    #expect(middleware.currentChain == .eth)
    #expect(switchedAddress == "0xSAME")
}
