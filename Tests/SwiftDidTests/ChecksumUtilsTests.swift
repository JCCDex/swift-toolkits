@testable import SwiftDid
import XCTest

/// EIP-55 checksum 标准测试向量（以太坊官方 EIP-55 文档用例）+ 与 Kotlin 对齐的非法输入行为。
final class ChecksumUtilsTests: XCTestCase {
    private func checksum(_ address: String) -> String? {
        try? ChecksumUtils.toChecksumAddress(address)
    }

    func testEip55Vectors() {
        XCTAssertEqual(
            self.checksum("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"),
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        )
        XCTAssertEqual(
            self.checksum("0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"),
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
        )
        XCTAssertEqual(
            self.checksum("0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB"),
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB"
        )
        XCTAssertEqual(
            self.checksum("0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"),
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"
        )
    }

    func testMixedCaseInputIsChecksummedIdempotently() {
        // 大写/混合输入 → 一律重新校验化（与 Kotlin 一致：40 位合法 hex 必被重写）
        XCTAssertEqual(
            self.checksum("0X5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED"),
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        )
    }

    func testInvalidLengthThrows() {
        XCTAssertNil(self.checksum("0x1234"))
        XCTAssertNil(self.checksum(""))
    }

    func testInvalidCharactersThrow() {
        XCTAssertNil(self.checksum("0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
    }

    func testZeroAddressIsStable() {
        // 全数字地址：无字母可校验，原样返回
        XCTAssertEqual(self.checksum("0x0000000000000000000000000000000000000000"), "0x0000000000000000000000000000000000000000")
    }
}
