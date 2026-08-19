@testable import SwiftNft
import XCTest

/// `EthTokenUriResolver` 纯函数 KAT（对齐 Kotlin `DefaultEthTokenUriResolver`，见 02 §4.2）：
/// calldata 只拼 selector + 32 字节十进制 tokenId（合约地址走 `to` 字段，不进 calldata）、
/// ABI string 解码假定 offset=32、URI 过 normalizeRemoteAssetUrl。网络路径（多节点 eth_call）
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
