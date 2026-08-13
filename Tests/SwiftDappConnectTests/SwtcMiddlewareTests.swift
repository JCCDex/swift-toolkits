import Foundation
@testable import SwiftDappConnect
import Testing

private func swtcAccount(_ address: String, isHD: Bool = false, parentId: String? = nil, publicKey: String = "0xpub") -> WalletAccount {
    WalletAccount(address: address, chain: .swtc, isHD: isHD, parentId: parentId, publicKey: publicKey)
}

@MainActor
private func makeSwtcMiddleware(
    accounts: [WalletAccount] = [],
    secretProvider: any SecretProvider = FakeSecretProvider(secret: "sec")
) -> SwtcMiddleware {
    SwtcMiddleware(
        accountProvider: FakeAccountProvider(accounts: accounts),
        secretProvider: secretProvider,
        nodeProvider: FakeNodeProvider(),
        signing: FakeWalletSigning()
    )
}

@Test @MainActor func `swtc request accounts filters swtc excluding hd roots`() async throws {
    let middleware = makeSwtcMiddleware(accounts: [
        swtcAccount("j1"),
        swtcAccount("j2", isHD: true, parentId: nil), // HD 根，排除
        swtcAccount("j3", isHD: true, parentId: "root"),
        makeAccount(address: "0xeth", chain: .eth)
    ])
    middleware.setRequestAccountsCallback { _ in true }

    let result = try await middleware.requestAccounts(origin: "https://dapp.com")
    #expect(result == ["j1", "j3"])
}

@Test @MainActor func `swtc request accounts throws without callback`() async throws {
    let middleware = makeSwtcMiddleware(accounts: [swtcAccount("j1")])
    await #expect(throws: DAppConnectError.userRejected("RequestAccountsCallback is not set")) {
        try await middleware.requestAccounts(origin: "https://dapp.com")
    }
}

@Test @MainActor func `swtc send transaction passes origin to secret provider`() async throws {
    let recorder = SecretRecorder()
    let middleware = makeSwtcMiddleware(
        accounts: [swtcAccount("j1")],
        secretProvider: FakeSecretProvider(secret: "sec", recorder: recorder)
    )

    let hash = try await middleware.sendTransaction(
        txParams: ["Account": "j1", "Fee": "10000"],
        origin: "https://dapp.com"
    )
    #expect(hash == "0xblobhash")
    let calls = await recorder.secretCalls
    #expect(calls.count == 1)
    #expect(calls[0].address == "j1")
    #expect(calls[0].origin == "https://dapp.com")
}

@Test @MainActor func `swtc send transaction rejects blank origin`() async throws {
    let middleware = makeSwtcMiddleware(accounts: [swtcAccount("j1")])
    await #expect(throws: DAppConnectError.internalError("origin must not be blank for sendTransaction")) {
        _ = try await middleware.sendTransaction(txParams: ["Account": "j1"], origin: "")
    }
}

@Test @MainActor func `swtc multi sign returns result object`() async throws {
    let middleware = makeSwtcMiddleware(accounts: [swtcAccount("j1")])
    let result = try await middleware.multiSign(
        msParams: ["account": "j1", "tx": ["Account": "j1"]],
        origin: "https://dapp.com"
    )
    #expect(result["result"] as? String == "0xms")
}

@Test @MainActor func `swtc get public key returns account public key`() async throws {
    let middleware = makeSwtcMiddleware(accounts: [swtcAccount("j1", publicKey: "0xKEY")])
    let publicKey = try await middleware.getPublicKey(address: "j1", origin: "https://dapp.com")
    #expect(publicKey == "0xKEY")
}

@Test @MainActor func `swtc nft transaction uses wallet internal origin`() async throws {
    let recorder = SecretRecorder()
    let middleware = makeSwtcMiddleware(
        accounts: [swtcAccount("j1")],
        secretProvider: FakeSecretProvider(secret: "sec", recorder: recorder)
    )

    let hash = try await middleware.sendNftTransactionWithPassword(
        address: "j1",
        to: "j2",
        tokenId: "1",
        memo: "memo",
        password: "pwd"
    )
    #expect(hash == "0xblobhash")
    let calls = await recorder.secretCalls
    #expect(calls.count == 1)
    #expect(calls[0].address == "j1")
    #expect(calls[0].origin == WebOrigin.walletInternal)
}
