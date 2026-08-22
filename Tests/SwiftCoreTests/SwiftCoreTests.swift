import SwiftCore
import XCTest

final class SwiftCoreTests: XCTestCase {

    // MARK: ChainType

    func testBip44CodeRoundTrip() {
        for chain in ChainType.allCases {
            XCTAssertEqual(ChainType.fromBip44Code(chain.bip44Code), chain)
        }
    }

    func testFromBip44CodeUnknownReturnsNil() {
        XCTAssertNil(ChainType.fromBip44Code(0))
        XCTAssertNil(ChainType.fromBip44Code(1))
    }

    func testLabelMatchesKotlin() {
        XCTAssertEqual(ChainType.eth.label, "Ethereum")
        XCTAssertEqual(ChainType.bsc.label, "Binance")
        XCTAssertEqual(ChainType.polygon.label, "Polygon")
        XCTAssertEqual(ChainType.arb1.label, "Arbitrum")
        XCTAssertEqual(ChainType.base.label, "Base")
        XCTAssertEqual(ChainType.swtc.label, "SWTC")
        XCTAssertEqual(ChainType.moac.label, "MOAC")
    }

    func testEvmChainId() {
        XCTAssertEqual(ChainType.eth.evmChainId, 1)
        XCTAssertNil(ChainType.swtc.evmChainId)
        XCTAssertTrue(ChainType.eth.isEvm)
        XCTAssertFalse(ChainType.swtc.isEvm)
        XCTAssertTrue(ChainType.swtc.isSwtc)
    }

    // MARK: Path

    func testDerivationPathMatchesKotlinToString() {
        XCTAssertEqual(Path(chain: 0).derivationPath, "m/44'/0'/0'/0/0")
        XCTAssertEqual(Path(chain: 2_147_483_708, account: 0, change: 0, index: 3).derivationPath, "m/44'/2147483708'/0'/0/3")
    }

    func testIsRootAndRoot() {
        XCTAssertTrue(Path(chain: 1).isRoot)
        XCTAssertFalse(Path(chain: 1, index: 1).isRoot)
        XCTAssertEqual(Path.root(chainType: .eth), Path(chain: ChainType.eth.bip44Code))
    }

    // MARK: WalletAccount

    func testStableIdConventionAndIsRootHD() {
        let account = WalletAccount(
            id: "0xabc#2147483708",
            address: "0xabc",
            chain: .eth,
            isHD: true,
            parentId: nil,
            path: Path.root(chainType: .eth)
        )
        XCTAssertTrue(account.isRootHD)
        let sub = WalletAccount(
            id: "0xabc#2147483708",
            address: "0xabc",
            chain: .eth,
            isHD: true,
            parentId: "root",
            path: Path(chain: ChainType.eth.bip44Code, index: 1)
        )
        XCTAssertFalse(sub.isRootHD, "parentId 非空 → 非根")
    }

    // MARK: Hex

    func testHexEncodeRoundTrip() {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x0F]
        XCTAssertEqual(Hex.encode(bytes), "deadbeef000f")
        XCTAssertEqual(Hex.decode("deadbeef000f"), bytes)
        XCTAssertEqual(Hex.encode([]), "")
        XCTAssertEqual(Hex.decode(""), [])
    }

    func testHexEncodeLowercase() {
        XCTAssertEqual(Hex.encode([0xAB, 0xCD]), "abcd")
    }

    func testHexDecodeRejectsInvalid() {
        XCTAssertNil(Hex.decode("abc"), "奇数长度 → nil")
        XCTAssertNil(Hex.decode("zz"), "非法字符 → nil")
        XCTAssertNil(Hex.decode("0x"), "含非 hex 字符 → nil")
    }

    func testHexDecodeAcceptsMixedCase() {
        XCTAssertEqual(Hex.decode("DeAdBeEf"), [0xDE, 0xAD, 0xBE, 0xEF])
    }
}
