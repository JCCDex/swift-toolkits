@testable import SwiftNft
import XCTest

/// `EthTokenUriResolver` 纯函数 KAT（对齐 Kotlin `DefaultEthTokenUriResolver`，见 02 §4.2）：
/// calldata 只拼 selector + 32 字节十进制 tokenId（合约地址走 `to` 字段，不进 calldata）、
/// ABI string 解码假定 offset=32、URI 过 normalizeRemoteAssetURL。网络路径（多节点 eth_call）
/// 由 demo/冒烟覆盖，此处不联网。
final class EthTokenUriResolverTests: XCTestCase {
    private let selector = "0xc87b56dd"
    private let defaultGateway = "https://ipfs.jccdex.cn/ipfs/"

    // MARK: buildTokenUriCallData

    func testCallDataForSmallTokenId() {
        XCTAssertEqual(
            EthTokenUriResolver.buildTokenUriCallData(tokenId: "4"),
            self.selector + String(repeating: "0", count: 63) + "4"
        )
    }

    func testCallDataForZero() {
        XCTAssertEqual(
            EthTokenUriResolver.buildTokenUriCallData(tokenId: "0"),
            self.selector + String(repeating: "0", count: 64)
        )
    }

    func testCallDataForMaxUint256() {
        // 2^256 - 1（十进制）→ 64 位全 f
        let maxUint256 = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        XCTAssertEqual(
            EthTokenUriResolver.buildTokenUriCallData(tokenId: maxUint256),
            self.selector + String(repeating: "f", count: 64)
        )
    }

    func testCallDataRejectsOverflow() {
        // 2^256（33 字节）超 uint256 → nil
        let twoTo256 = "115792089237316195423570985008687907853269984665640564039457584007913129639936"
        XCTAssertNil(EthTokenUriResolver.buildTokenUriCallData(tokenId: twoTo256))
    }

    func testCallDataRejectsNonNumeric() {
        XCTAssertNil(EthTokenUriResolver.buildTokenUriCallData(tokenId: "abc"))
        XCTAssertNil(EthTokenUriResolver.buildTokenUriCallData(tokenId: ""))
        XCTAssertNil(EthTokenUriResolver.buildTokenUriCallData(tokenId: "-1"))
        XCTAssertNil(EthTokenUriResolver.buildTokenUriCallData(tokenId: "1.5"))
    }

    // MARK: decodeAbiString

    func testDecodeAbiStringPlain() {
        XCTAssertEqual(EthTokenUriResolver.decodeAbiString(self.abiEncode("hi")), "hi")
    }

    func testDecodeAbiStringUri() {
        let uri = "ipfs://bafy123/meta/8.json"
        XCTAssertEqual(EthTokenUriResolver.decodeAbiString(self.abiEncode(uri)), uri)
    }

    func testDecodeAbiStringIgnoresTrailingGarbage() {
        // Kotlin 取前 length 字节，尾随垃圾截断
        XCTAssertEqual(EthTokenUriResolver.decodeAbiString(self.abiEncode("hi") + "deadbeef"), "hi")
    }

    func testDecodeAbiStringNilForNullOrEmpty() {
        XCTAssertNil(EthTokenUriResolver.decodeAbiString(nil))
        XCTAssertNil(EthTokenUriResolver.decodeAbiString(""))
        XCTAssertNil(EthTokenUriResolver.decodeAbiString("0x"))
    }

    func testDecodeAbiStringRejectsTooShort() {
        // 不足 offset(64) + length(64) 共 128 hex 位 → nil
        XCTAssertNil(EthTokenUriResolver.decodeAbiString("0x" + String(repeating: "0", count: 100)))
    }

    func testDecodeAbiStringRejectsBadLength() {
        // length 超大（0xffffffff）→ 数据区越界 → nil
        let bad = "0x" + String(repeating: "0", count: 63) + "20" + String(repeating: "f", count: 64) + "6869"
        XCTAssertNil(EthTokenUriResolver.decodeAbiString(bad))
    }

    func testDecodeAbiStringRejectsNonHexLength() {
        let bad = "0x" + String(repeating: "0", count: 63) + "20" + String(repeating: "z", count: 64)
        XCTAssertNil(EthTokenUriResolver.decodeAbiString(bad))
    }

    func testDecodeAbiStringRejectsOverflowLength() {
        // P0-4：length 字来自链上不可信数据。旧实现 length * 2 在 2^62..<2^63 区间
        // 溢出 Int64 → 运行时崩溃（恶意合约远程可触发）；修复后必须在乘法前界长 → nil。
        // 布局：offset(62 个 0+"20") + length(64 hex) + 数据（对齐 [64..<128] 读取约定）。
        // 2^62 = 0x4000000000000000
        let twoTo62 = "0x" + String(repeating: "0", count: 62) + "20"
            + String(repeating: "0", count: 48) + "4000000000000000" + "6869"
        XCTAssertNil(EthTokenUriResolver.decodeAbiString(twoTo62), "length=2^62 不得溢出崩溃，应返回 nil")
        // 最大可解析值 2^63-1 = 0x7fffffffffffffff
        let maxInt64 = "0x" + String(repeating: "0", count: 62) + "20"
            + String(repeating: "0", count: 48) + "7fffffffffffffff" + "6869"
        XCTAssertNil(EthTokenUriResolver.decodeAbiString(maxInt64), "length=2^63-1 不得溢出崩溃，应返回 nil")
    }

    func testDecodeAbiStringLengthExactlyFitsData() {
        // 边界：length 恰好等于可用数据长度 → 正常解码（防过度拦截）
        XCTAssertEqual(EthTokenUriResolver.decodeAbiString(self.abiEncode("hi")), "hi")
        let exactlyFits = "0x" + String(repeating: "0", count: 62) + "20"
            + String(repeating: "0", count: 62) + "02" + "6869"
        XCTAssertEqual(EthTokenUriResolver.decodeAbiString(exactlyFits), "hi", "length=可用数据长度应解码成功")
    }

    // MARK: normalizeTokenMetadataUri

    func testNormalizeIpfsUriToGateway() {
        XCTAssertEqual(
            EthTokenUriResolver.normalizeTokenMetadataUri("ipfs://bafy123/8.png"),
            "\(self.defaultGateway)bafy123/8.png"
        )
    }

    func testNormalizeHttpUriPassthrough() {
        let uri = "https://example.com/8.json"
        XCTAssertEqual(EthTokenUriResolver.normalizeTokenMetadataUri(uri), uri)
    }

    func testNormalizeHttpIpfsPathCanonicalized() {
        XCTAssertEqual(
            EthTokenUriResolver.normalizeTokenMetadataUri("https://cdn.example.com/ipfs/QmFoo/a.png"),
            "\(self.defaultGateway)QmFoo/a.png"
        )
    }

    func testNormalizeNilForBlank() {
        XCTAssertNil(EthTokenUriResolver.normalizeTokenMetadataUri(nil))
        XCTAssertNil(EthTokenUriResolver.normalizeTokenMetadataUri(""))
        XCTAssertNil(EthTokenUriResolver.normalizeTokenMetadataUri("  "))
    }

    // MARK: 记忆化（review D-1：成功缓存 + in-flight 去重 + 失败不缓存）

    func testResolveCachesSuccessAndDedupesInflight() async {
        let client = CountingFetchRpcClient()
        let resolver = EthTokenUriResolver(
            getRpcNode: { _ in "https://rpc.example.com" },
            httpClient: client,
            gateway: self.defaultGateway
        )
        // 并发 5 次同 key：in-flight 去重 → 只发 1 次 eth_call，全部拿到结果
        let results = await withTaskGroup(of: String?.self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "7", chainId: 1)
                }
            }
            var values: [String?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        XCTAssertEqual(client.rpcCallCount, 1, "并发同 key 只发一次 eth_call")
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0 == "\(self.defaultGateway)bafy123/8.png" }, "全部命中同一成功结果")

        // 第二次调用（缓存命中）不再发 RPC
        let second = await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "7", chainId: 1)
        XCTAssertEqual(client.rpcCallCount, 1, "缓存命中不再发 eth_call")
        XCTAssertEqual(second, "\(self.defaultGateway)bafy123/8.png")
    }

    func testResolveDoesNotCacheFailure() async {
        let client = FailingFetchRpcClient()
        let resolver = EthTokenUriResolver(
            getRpcNode: { _ in "https://rpc.example.com" },
            httpClient: client,
            gateway: self.defaultGateway
        )
        let first = await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "7", chainId: 1)
        XCTAssertNil(first)
        let second = await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "7", chainId: 1)
        XCTAssertNil(second)
        XCTAssertEqual(client.rpcCallCount, 2, "失败不缓存，可重试")
    }

    func testResolveUsesInjectedGateway() async {
        let customGateway = "https://custom-gateway.example/ipfs/"
        let client = CountingFetchRpcClient()
        let resolver = EthTokenUriResolver(
            getRpcNode: { _ in "https://rpc.example.com" },
            httpClient: client,
            gateway: customGateway
        )
        let uri = await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "7", chainId: 1)
        XCTAssertEqual(uri, "\(customGateway)bafy123/8.png", "init 注入 gateway 单次归一（review D-2）")
    }

    // MARK: 工具

    /// ABI 编码字符串：offset(0x20，64 hex 位) + length(64 hex) + utf8 数据（32 字节字对齐补零），无 0x 前缀。
    private func abiEncode(_ value: String) -> String {
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        let offset = String(repeating: "0", count: 62) + "20"
        let length = String(format: "%064x", hex.count / 2)
        let padded = hex + String(repeating: "0", count: (64 - hex.count % 64) % 64)
        return offset + length + padded
    }
}

/// 桩：记录 eth_call 次数，返回固定 ABI 编码的 `ipfs://bafy123/8.png`。
/// @unchecked Sendable：测试桩，`rpcCallCount` 用锁保护（并发去重用例下安全计数）。
private final class CountingFetchRpcClient: NftHttpClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _rpcCallCount = 0
    var rpcCallCount: Int {
        self.lock.withLock { self._rpcCallCount }
    }

    func fetchJson(_: URL) async throws -> Data? {
        nil
    }

    func fetchText(_: URL) async throws -> String? {
        nil
    }

    func fetchRpc(_: URL, body _: Data) async throws -> Data? {
        self.lock.withLock { self._rpcCallCount += 1 }
        let uri = "ipfs://bafy123/8.png"
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "result": Self.abiEncode(uri), "id": 1])
    }

    /// ABI 编码（与测试工具同款：offset + length + utf8 数据对齐）。
    private static func abiEncode(_ value: String) -> String {
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        let offset = String(repeating: "0", count: 62) + "20"
        let length = String(format: "%064x", hex.count / 2)
        let padded = hex + String(repeating: "0", count: (64 - hex.count % 64) % 64)
        return "0x" + offset + length + padded
    }
}

/// 桩：eth_call 一律失败（nil）。
private final class FailingFetchRpcClient: NftHttpClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _rpcCallCount = 0
    var rpcCallCount: Int {
        self.lock.withLock { self._rpcCallCount }
    }

    func fetchJson(_: URL) async throws -> Data? {
        nil
    }

    func fetchText(_: URL) async throws -> String? {
        nil
    }

    func fetchRpc(_: URL, body _: Data) async throws -> Data? {
        self.lock.withLock { self._rpcCallCount += 1 }
        return nil
    }
}
