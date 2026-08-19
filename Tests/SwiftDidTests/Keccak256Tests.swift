@testable import SwiftDid
import XCTest

/// keccak-256 KAT：向量由 pycryptodome（Keccak-256）独立生成，含空串 / 短消息 / 单块边界 /
/// 多块 / 长消息——自实现必须全量通过（设计文档 04 坑 #3 的 KAT 交叉验证要求）。
final class Keccak256Tests: XCTestCase {
    private func hex(_ input: String) -> String {
        Keccak256.hex(data: Keccak256.hash(data: Data(input.utf8)))
    }

    private func hexBytes(_ bytes: [UInt8]) -> String {
        Keccak256.hex(data: Keccak256.hash(data: Data(bytes)))
    }

    func testEmptyString() {
        XCTAssertEqual(self.hex(""), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    func testABC() {
        XCTAssertEqual(self.hex("abc"), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    }

    func testQuickBrownFox() {
        XCTAssertEqual(self.hex("The quick brown fox jumps over the lazy dog"), "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15")
    }

    func testSingleBlockBoundary136Bytes() {
        XCTAssertEqual(self.hexBytes(Array(0 ..< 136)), "7ce759f1ab7f9ce437719970c26b0a66ff11fe3e38e17df89cf5d29c7d7f807e")
    }

    func testMultiBlock137Bytes() {
        XCTAssertEqual(self.hexBytes(Array(0 ..< 137)), "ac73d4fae68b8453f764007c1a20ce95994187861f0c3227a3a8e99a73a3b1db")
    }

    func testMultiBlock200X() {
        XCTAssertEqual(self.hexBytes([UInt8](repeating: 0x78, count: 200)), "3c3800defb6a25a70a2737e0716eeb5d270559ad3cad8f6abddac58802d7158e")
    }

    func testLongMessage300Bytes() {
        XCTAssertEqual(self.hexBytes((0 ..< 300).map { UInt8($0 % 256) }), "a679e749a6af300c36e7ff2255d220864eab27b382f9cfdc5aa4d13563ba36ff")
    }

    func testBytesZeroToThirtyOne() {
        XCTAssertEqual(self.hexBytes(Array(0 ..< 32)), "8ae1aa597fa146ebd3aa2ceddf360668dea5e526567e92b0321816a4e895bd2d")
    }

    /// 单字节填充边界（pad10*1 需 0x81）：长度 ≡ 135 (mod 136) 时此前实现把末字节 `= 0x80` 覆盖了 0x01，
    /// 得到错误哈希——这两个向量锁死修正（`|= 0x80`）。
    func testSingleBytePaddingBoundary135Bytes() {
        XCTAssertEqual(self.hexBytes((0 ..< 135).map { UInt8($0) }), "cbdfd9dee5faad3818d6b06f95a219fd290b0e1706f6a82e5a595b9ce9faca62")
    }

    func testSingleBytePaddingBoundary271Bytes() {
        XCTAssertEqual(self.hexBytes((0 ..< 271).map { UInt8($0 % 256) }), "7c974895b2a88303ff2dc6b58f438ceb0b298cac91099ac0539cc0f477506191")
    }
}
