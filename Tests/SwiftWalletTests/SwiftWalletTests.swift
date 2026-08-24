import Foundation
@testable import SwiftWallet
import SwiftWebviewBridge
import Testing

// MARK: - Fake 桥（对应 Kotlin `installBridgeForTest`）

@MainActor
final class FakeWalletBridge: EngineBridge {
    var recordedCalls: [(method: String, params: [String: Any]?)] = []
    var responses: [String: String] = [:]
    var startCallCount = 0
    var destroyCallCount = 0

    func start() throws {
        self.startCallCount += 1
    }

    func destroy() {
        self.destroyCallCount += 1
    }

    func call(
        method: String,
        params: [String: Any]?
    ) async throws -> String {
        try await self.call(method: method, params: params, timeoutMs: 30000, readyWaitMs: 15000)
    }

    func call(
        method: String,
        params: [String: Any]?,
        timeoutMs _: TimeInterval,
        readyWaitMs _: TimeInterval
    ) async throws -> String {
        self.recordedCalls.append((method, params))
        return self.responses[method] ?? ""
    }

    func callAs<T: Decodable>(
        method: String,
        params: [String: Any]?,
        as type: T.Type
    ) async throws -> T {
        try await self.callAs(method: method, params: params, as: type, timeoutMs: 30000, readyWaitMs: 15000)
    }

    func callAs<T: Decodable>(
        method: String,
        params: [String: Any]?,
        as _: T.Type,
        timeoutMs _: TimeInterval,
        readyWaitMs _: TimeInterval
    ) async throws -> T {
        self.recordedCalls.append((method, params))
        let raw = self.responses[method] ?? "{}"
        return try JSONDecoder().decode(T.self, from: Data(raw.utf8))
    }
}

@MainActor
private func makeWallet(bridge: FakeWalletBridge) -> SwiftWallet {
    SwiftWallet(bridge: bridge)
}

// MARK: - 生命周期

@Test @MainActor func `call before start throws not initialized`() async {
    let bridge = FakeWalletBridge()
    let wallet = makeWallet(bridge: bridge)

    await #expect(throws: SwiftWalletError.notInitialized) {
        _ = try await wallet.generateMnemonic()
    }
}

@Test @MainActor func `start is idempotent and destroy resets`() async throws {
    let bridge = FakeWalletBridge()
    let wallet = makeWallet(bridge: bridge)

    try wallet.start()
    try wallet.start()
    #expect(bridge.startCallCount == 1)

    wallet.destroy()
    #expect(bridge.destroyCallCount == 1)
    await #expect(throws: SwiftWalletError.notInitialized) {
        _ = try await wallet.validateMnemonic("word")
    }
}

// MARK: - 助记词 / 派生

@Test @MainActor func `generate mnemonic parses model and passes params`() async throws {
    let bridge = FakeWalletBridge()
    bridge.responses["generateMnemonic"] = #"{"value":"a b c d e f g h i j k l","language":"english"}"#
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    let mnemonic = try await wallet.generateMnemonic(length: 128)

    #expect(mnemonic.value == "a b c d e f g h i j k l")
    #expect(mnemonic.language == "english")
    #expect(bridge.recordedCalls.first?.method == "generateMnemonic")
    #expect(bridge.recordedCalls.first?.params?["length"] as? Int == 128)
}

@Test @MainActor func `derive child parses sub wallet and chain param`() async throws {
    let bridge = FakeWalletBridge()
    bridge.responses["deriveChild"] = """
    {"chain":2147483708,"address":"0xabc123",
     "path":{"chain":2147483708,"account":0,"change":0,"index":0},
     "keypair":{"privateKey":"0xpk","publicKey":"0xpub"}}
    """
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    let sub = try await wallet.deriveChild(mnemonic: "a b c", chain: 2_147_483_708)

    #expect(sub.address == "0xabc123")
    #expect(sub.chain == 2_147_483_708)
    #expect(sub.keypair.privateKey == "0xpk")
    #expect(sub.path.derivationPath == "m/44'/2147483708'/0'/0/0")
    #expect(bridge.recordedCalls.first?.params?["chain"] as? Int64 == 2_147_483_708)
}

@Test @MainActor func `hd wallet from mnemonic parses accounts array`() async throws {
    let bridge = FakeWalletBridge()
    bridge.responses["hdWalletFromMnemonic"] = """
    {"mnemonic":"a b c","address":"0xroot","language":"english",
     "keypair":{"privateKey":"pk0","publicKey":"pub0"},
     "accounts":[{"chain":2147483708,"address":"0xeth","path":{"chain":2147483708,"account":0,"change":0,"index":0},
                  "keypair":{"privateKey":"pk1","publicKey":"pub1"}}]}
    """
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    let result = try await wallet.hdWalletFromMnemonic(mnemonic: "a b c", chains: [2_147_483_708])

    #expect(result.address == "0xroot")
    #expect(result.accounts.count == 1)
    #expect(result.accounts.first?.address == "0xeth")
    #expect(bridge.recordedCalls.first?.params?["chains"] as? [Int64] == [2_147_483_708])
}

@Test @MainActor func `boolean methods parse raw strings`() async throws {
    let bridge = FakeWalletBridge()
    bridge.responses["validateMnemonic"] = "true"
    bridge.responses["validatePrivateKey"] = "false"
    bridge.responses["isValidAddress"] = " true "
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    #expect(try await wallet.validateMnemonic("a b c") == true)
    #expect(try await wallet.validatePrivateKey("pk", chain: 2_147_483_708) == false)
    #expect(try await wallet.isValidAddress("addr") == true)
}

// MARK: - SWTC 交易（含 JS 缺口补齐的方法）

@Test @MainActor func `build swtc create and cancel order forward`() async throws {
    let bridge = FakeWalletBridge()
    bridge.responses["buildSwtcCreateOrder"] = #"{"Sequence":1,"TransactionType":"OfferCreate"}"#
    bridge.responses["buildSwtcCancelOrder"] = #"{"Sequence":1,"TransactionType":"OfferCancel"}"#
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    let created = try await wallet.buildSwtcCreateOrder(
        address: "jAddr", amount: "1", base: "SWTC", counter: "JCC",
        sum: "100", type: "sell", platform: "P", issuer: "I"
    )
    #expect(created.contains("OfferCreate"))
    #expect(bridge.recordedCalls[0].params?["platform"] as? String == "P")
    #expect(bridge.recordedCalls[0].params?["issuer"] as? String == "I")

    _ = try await wallet.buildSwtcCancelOrder(address: "jAddr", sequence: 42)
    #expect(bridge.recordedCalls[1].params?["sequence"] as? Int64 == 42)
}

@Test @MainActor func `build swtc create order omits nil optionals`() async throws {
    let bridge = FakeWalletBridge()
    bridge.responses["buildSwtcCreateOrder"] = #"{"Sequence":1}"#
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    _ = try await wallet.buildSwtcCreateOrder(
        address: "jAddr", amount: "1", base: "SWT", counter: "JCC",
        sum: "100", type: "sell"
    )

    let params = bridge.recordedCalls.first?.params ?? [:]
    #expect(params["platform"] == nil)
    #expect(params["issuer"] == nil)
    #expect(params["base"] as? String == "SWT")
}

// MARK: - WalletSigning 对接

@Test @MainActor func `wallet signing personal sign forwards`() async throws {
    let bridge = FakeWalletBridge()
    // call 路径：真实桥返回已解引号的字符串
    bridge.responses["personalSign"] = "0x-sig"
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    let signature = try await wallet.personalSign(privateKey: "0xpk", message: "hello")

    #expect(signature == "0x-sig")
    #expect(bridge.recordedCalls.first?.method == "personalSign")
    #expect(bridge.recordedCalls.first?.params?["data"] as? String == "hello")
}

@Test @MainActor func `wallet signing nft transfer parses json string to dict`() async throws {
    let bridge = FakeWalletBridge()
    bridge.responses["buildSwtcNftTransfer"] = #"{"TransactionType":"NFTTokenTransferPage","Sequence":7}"#
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    let tx: [String: Any] = try await wallet.buildSwtcNftTransfer(address: "jAddr", to: "jTo", tokenId: "1", memo: "m")

    #expect(tx["TransactionType"] as? String == "NFTTokenTransferPage")
    #expect(tx["Sequence"] as? Int == 7)
}

@Test @MainActor func `wallet signing nft transfer throws on invalid response`() async throws {
    // review SwiftWallet P1#1：桥返回非 JSON 对象不再吞错返回 [:]
    let bridge = FakeWalletBridge()
    bridge.responses["buildSwtcNftTransfer"] = "not-json"
    let wallet = makeWallet(bridge: bridge)
    try wallet.start()

    await #expect(throws: SwiftWalletError.self) {
        let _: [String: Any] = try await wallet.buildSwtcNftTransfer(address: "jAddr", to: "jTo", tokenId: "1", memo: "m")
    }
}

@Test func `generate hd wallet result decodes missing accounts as empty`() throws {
    // review SwiftWallet P1#2：JS 缺 accounts 键 → []（合成 Decodable 会 keyNotFound）
    let json = #"{"mnemonic":"m","address":"a","language":"english","keypair":{"privateKey":"pk","publicKey":"pub"}}"#
    let data = Data(json.utf8)
    let result = try JSONDecoder().decode(GenerateHDWalletResult.self, from: data)
    #expect(result.accounts.isEmpty)
    #expect(result.address == "a")
}

@Test func `generate hd wallet result decodes present accounts`() throws {
    let json = #"{"mnemonic":"m","address":"a","language":"english","keypair":{"privateKey":"pk","publicKey":"pub"},"accounts":[{"chain":60,"address":"0x1","path":{"chain":60,"account":0,"change":0,"index":0},"keypair":{"privateKey":"pk1","publicKey":"pub1"}}]}"#
    let data = Data(json.utf8)
    let result = try JSONDecoder().decode(GenerateHDWalletResult.self, from: data)
    #expect(result.accounts.count == 1)
    #expect(result.accounts.first?.address == "0x1")
}
