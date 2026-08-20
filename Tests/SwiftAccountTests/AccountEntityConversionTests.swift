import GRDB
@testable import SwiftAccount
import SwiftCore
import XCTest

/// AccountRecord ↔ WalletAccount 双向转换测试（对齐 Kotlin `AccountEntityTest`）：
/// 未知 chain 回退 .eth、path 默认 account/change 为 0、null pathIndex → nil path、
/// from/round-trip 字段映射。
final class AccountEntityConversionTests: XCTestCase {
    func testUnknownChainFallsBackToEth() {
        let record = AccountRecord(
            id: "id", address: "0x1", chain: 0, name: "n", isHD: false,
            parentId: nil, pathAccount: nil, pathChange: nil, pathIndex: nil, publicKey: "p"
        )
        XCTAssertEqual(record.account.chain, .eth, "未知 BIP44 code → 回退 .eth（对齐 Kotlin）")
    }

    func testPathDefaultsAccountAndChangeToZero() {
        let record = AccountRecord(
            id: "id", address: "0x1", chain: ChainType.eth.bip44Code, name: "n", isHD: true,
            parentId: "root", pathAccount: nil, pathChange: nil, pathIndex: 3, publicKey: "p"
        )
        let path = record.account.path
        XCTAssertEqual(path?.index, 3)
        XCTAssertEqual(path?.account, 0, "pathAccount 缺省 → 0")
        XCTAssertEqual(path?.change, 0, "pathChange 缺省 → 0")
        XCTAssertEqual(path?.chain, ChainType.eth.bip44Code, "path.chain 按账户 chain 列重建")
    }

    func testNullPathIndexYieldsNullPath() {
        let record = AccountRecord(
            id: "id", address: "0x1", chain: ChainType.swtc.bip44Code, name: "n", isHD: false,
            parentId: nil, pathAccount: nil, pathChange: nil, pathIndex: nil, publicKey: "p"
        )
        XCTAssertNil(record.account.path, "pathIndex 为 null → 传统账户无路径")
    }

    func testFromWalletAccountRoundTrips() {
        let account = WalletAccount(
            id: "0x1#\(ChainType.eth.bip44Code)",
            address: "0x1",
            chain: .eth,
            name: "n",
            isHD: true,
            parentId: "root",
            path: Path(chain: ChainType.eth.bip44Code, account: 0, change: 1, index: 2),
            publicKey: "pub"
        )
        let record = AccountRecord(account: account)
        XCTAssertEqual(record.id, account.id)
        XCTAssertEqual(record.chain, ChainType.eth.bip44Code)
        XCTAssertEqual(record.isHD, true)
        XCTAssertEqual(record.pathAccount, 0)
        XCTAssertEqual(record.pathChange, 1)
        XCTAssertEqual(record.pathIndex, 2)
        XCTAssertEqual(record.account, account, "round-trip 等值")
    }
}
