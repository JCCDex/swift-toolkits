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

    func testIsHDRootIgnoresPath() {
        // 中间件过滤谓词：isHD && parentId == nil（不查 path）——与 isRootHD 区分
        let root = WalletAccount(address: "0xr", chain: .eth, isHD: true, parentId: nil, path: Path.root(chainType: .eth))
        XCTAssertTrue(root.isHDRoot)
        XCTAssertTrue(root.isRootHD)

        // path 非根但 parentId == nil → 过滤谓词仍视为根（不查 path）
        let nonRootPath = WalletAccount(address: "0xr2", chain: .eth, isHD: true, parentId: nil, path: Path(chain: 1, index: 5))
        XCTAssertTrue(nonRootPath.isHDRoot)
        XCTAssertFalse(nonRootPath.isRootHD, "isRootHD 额外要求 path 为根")

        let child = WalletAccount(address: "0xc", chain: .eth, isHD: true, parentId: "root", path: Path.root(chainType: .eth))
        XCTAssertFalse(child.isHDRoot)
        XCTAssertFalse(child.isRootHD)

        let traditional = WalletAccount(address: "0xt", chain: .eth, isHD: false, parentId: nil)
        XCTAssertFalse(traditional.isHDRoot)
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

    // MARK: Json

    func testJsonReadStringCoercion() {
        let dict: [String: Any] = ["s": "str", "b": true, "n": 42, "d": 1.5, "nil": NSNull()]
        XCTAssertEqual(Json.readString(dict, "s", default: ""), "str")
        XCTAssertEqual(Json.readString(dict, "b", default: ""), "true")
        XCTAssertEqual(Json.readString(dict, "n", default: ""), "42")
        XCTAssertEqual(Json.readString(dict, "d", default: ""), "1.5")
        XCTAssertEqual(Json.readString(dict, "missing", default: ""), "")
        XCTAssertEqual(Json.readString(dict, "missing", default: "def"), "def")
        XCTAssertEqual(Json.readString(dict, "nil", default: ""), "", "NSNull → 默认值")
    }

    func testJsonReadValuePathTraversal() {
        let root: [String: Any] = [
            "credentialSubject": ["tokenId": "7", "active": true],
            "issuanceDate": "2025-01-01",
            "empty": NSNull()
        ]
        XCTAssertEqual(Json.readValue(root, "credentialSubject.tokenId") as? String, "7")
        XCTAssertEqual(Json.readValue(root, "$.credentialSubject.tokenId") as? String, "7", "$. 前缀剥离")
        XCTAssertNil(Json.readValue(root, "credentialSubject.missing"))
        XCTAssertNil(Json.readValue(root, "missing.path"))
        XCTAssertNil(Json.readValue(root, "empty"), "NSNull → nil")
    }

    func testJsonReadStringAndLongCoercion() {
        let root: [String: Any] = [
            "name": "avatar",
            "count": 5,
            "countStr": "5",
            "flag": true
        ]
        XCTAssertEqual(Json.readString(root, "name"), "avatar")
        XCTAssertEqual(Json.readString(root, "flag"), "true")
        XCTAssertEqual(Json.readString(root, "count"), "5")
        XCTAssertEqual(Json.readLong(root, "count"), 5)
        XCTAssertEqual(Json.readLong(root, "countStr"), 5)
        XCTAssertNil(Json.readLong(root, "name"))
    }

    func testJsonReadStringAndLongDefaultValue() {
        let root: [String: Any] = ["name": "avatar", "chainId": 7]
        XCTAssertEqual(Json.readString(root, "missing", default: ""), "", "缺失 → 默认值")
        XCTAssertEqual(Json.readString(root, "name", default: ""), "avatar", "命中 → 原值")
        XCTAssertEqual(Json.readLong(root, "missing", default: 0), 0)
        XCTAssertEqual(Json.readLong(root, "chainId", default: 0), 7)
        XCTAssertNil(Json.readString(root, "missing"), "无 default 重载仍返回 nil")
    }

    // MARK: isBlank / nilIfBlank

    func testIsBlank() {
        XCTAssertTrue(isBlank(nil))
        XCTAssertTrue(isBlank(""))
        XCTAssertTrue(isBlank("  \n\t"))
        XCTAssertFalse(isBlank("a"))
        XCTAssertTrue("  ".isBlank)
        XCTAssertFalse("a".isBlank)
    }

    func testNilIfBlank() {
        XCTAssertNil("".nilIfBlank)
        XCTAssertNil("   ".nilIfBlank)
        XCTAssertEqual("abc".nilIfBlank, "abc")
    }

    // MARK: 地址比较

    func testAddressEqualsAndNormalized() {
        // EIP-55 混合大小写地址按小写化比较
        let mixed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        XCTAssertTrue(mixed.addressEquals("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"))
        XCTAssertTrue("0xABC".addressEquals("0xabc"))
        XCTAssertFalse("0xabc".addressEquals("0xabcd"))
        XCTAssertEqual(mixed.normalizedAddress, "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed")
    }

    // MARK: 字符串处理（trimmingPrefix / removingPrefix / hex2utf8）

    func testTrimmingAndRemovingPrefix() {
        XCTAssertEqual("///ipfs".trimmingPrefix("/"), "ipfs")
        XCTAssertEqual("/ipfs/".trimmingPrefix("/"), "ipfs/")
        XCTAssertEqual("ipfs://xyz".removingPrefix("ipfs://"), "xyz")
        XCTAssertEqual("abc".removingPrefix("zz"), "abc", "不匹配 → 原样")
        XCTAssertEqual("/ipfs/Qm".trimmingPrefix("/").removingPrefix("ipfs/"), "Qm")
    }

    func testHexDecodedUTF8() {
        XCTAssertEqual("68656c6c6f".hex2utf8(), "hello")
        XCTAssertEqual("0x68656c6c6f".hex2utf8(), "hello", "剥 0x 前缀")
        XCTAssertEqual("68 65 6c 6c 6f".hex2utf8(), "hello", "去空白")
        XCTAssertEqual("zz".hex2utf8(), "", "非法 → 空")
        XCTAssertEqual("abc".hex2utf8(), "", "奇数长度 → 空")
    }
}
