@testable import SwiftNft
import XCTest

final class NftUrlUtilsTests: XCTestCase {
    private let defaultGateway = "https://ipfs.jccdex.cn/ipfs/"

    // MARK: normalizeAssetURL KAT（对齐 Kotlin NftSdkTest）

    func testNormalizeIpfsUriToGateway() {
        XCTAssertEqual(
            normalizeRemoteAssetURL("ipfs://bafy123/avatar.png"),
            "\(self.defaultGateway)bafy123/avatar.png"
        )
    }

    func testNormalizeSlashIpfsPrefix() {
        XCTAssertEqual(normalizeRemoteAssetURL("/ipfs/bafy123/avatar.png"), "\(self.defaultGateway)bafy123/avatar.png")
        XCTAssertEqual(normalizeRemoteAssetURL("ipfs/bafy123/avatar.png"), "\(self.defaultGateway)bafy123/avatar.png")
    }

    func testNormalizeBareCid() {
        XCTAssertEqual(normalizeRemoteAssetURL("QmHash/avatar.png"), "\(self.defaultGateway)QmHash/avatar.png")
        XCTAssertEqual(normalizeRemoteAssetURL("bafyHash/meta.json"), "\(self.defaultGateway)bafyHash/meta.json")
    }

    func testNormalizeHttpIpfsPathCanonicalized() {
        XCTAssertEqual(
            normalizeRemoteAssetURL("https://cdn.thirdparty.com/ipfs/xyz/a.png"),
            "\(self.defaultGateway)xyz/a.png"
        )
    }

    func testCanonicalizeHttpIpfsStripsDotDotSegments() {
        // review SwiftNft 补充细节：`/ipfs/../../etc` 剥掉 `..` 段，不拼接进网关 URL
        XCTAssertEqual(canonicalizeHttpIpfsURL("https://evil.com/ipfs/QmFoo/a.png"), "\(self.defaultGateway)QmFoo/a.png")
        XCTAssertEqual(canonicalizeHttpIpfsURL("https://evil.com/ipfs/../../etc/passwd"), "\(self.defaultGateway)etc/passwd")
        XCTAssertNil(canonicalizeHttpIpfsURL("https://evil.com/ipfs/../.."), "剥完为空 → nil")
        XCTAssertNil(canonicalizeHttpIpfsURL("https://evil.com/other/../x.png"), "非 /ipfs/ 路径 → nil")
    }

    func testNormalizeRelativePathAgainstMetadataUrl() {
        XCTAssertEqual(
            normalizeRemoteAssetURL("assets/avatar.png", baseUrl: "https://example.com/meta.json"),
            "https://example.com/assets/avatar.png"
        )
    }

    func testNormalizeProtocolRelative() {
        XCTAssertEqual(
            normalizeRemoteAssetURL("//host/a.png", baseUrl: "https://example.com/meta.json"),
            "https://host/a.png"
        )
    }

    func testNormalizeNoBaseKeepsRawValue() {
        // 对齐 Kotlin：无 base 的不可解析路径返回原样（不判 nil）。
        XCTAssertEqual(normalizeRemoteAssetURL("not-a-url"), "not-a-url")
    }

    func testNormalizeJsonPayloadReturnsNil() {
        XCTAssertNil(normalizeRemoteAssetURL(#"{"image":"x"}"#))
        XCTAssertNil(normalizeRemoteAssetURL(#"["a"]"#))
    }

    func testNormalizeBlankReturnsNil() {
        XCTAssertNil(normalizeRemoteAssetURL(nil))
        XCTAssertNil(normalizeRemoteAssetURL("   "))
    }

    func testNormalizeDataUrlPassthrough() {
        let dataURL = "data:image/png;base64,AAAA"
        XCTAssertEqual(normalizeRemoteAssetURL(dataURL), dataURL)
    }

    func testNormalizeCustomGatewayThreadsThrough() {
        let custom = "https://custom.gateway/ipfs/"
        XCTAssertEqual(
            normalizeRemoteAssetURL("ipfs://bafy123/a.png", gateway: custom),
            "\(custom)bafy123/a.png"
        )
        XCTAssertEqual(
            normalizeRemoteAssetURL("https://cdn.x.com/ipfs/xyz", gateway: custom),
            "\(custom)xyz"
        )
    }

    // MARK: isSupportedRemoteAssetURL

    func testIsLoadableRemoteAssetUrl() {
        XCTAssertTrue(isLoadableRemoteAssetURL("https://example.com/a.png"))
        XCTAssertTrue(isLoadableRemoteAssetURL("http://example.com/a.png"))
        XCTAssertTrue(isLoadableRemoteAssetURL("data:image/png;base64,AAAA"))
        XCTAssertFalse(isLoadableRemoteAssetURL("ipfs://bafy123/a.png"))
        XCTAssertFalse(isLoadableRemoteAssetURL(nil))
        XCTAssertFalse(isLoadableRemoteAssetURL(""))
    }

    func testIsDataImageUrl() {
        XCTAssertTrue(isDataImageURL("data:image/png;base64,AAAA"))
        XCTAssertTrue(isDataImageURL("data:image/svg+xml;base64,AAAA"))
        XCTAssertFalse(isDataImageURL("data:text/html;base64,AAAA"))
        XCTAssertFalse(isDataImageURL("https://example.com/a.png"))
        XCTAssertFalse(isDataImageURL(nil))
    }

    // MARK: extractMetadataImageURLFromBody（原公开 2 参便捷版已并入门面，纯函数走内部版）

    func testExtractResolvedMetadataImageUrl() {
        XCTAssertEqual(
            extractMetadataImageURLFromBody(#"{"image":"./nft/avatar.png"}"#, metadataUri: "https://example.com/meta.json"),
            "https://example.com/nft/avatar.png"
        )
    }

    func testExtractImageKeyOrderImageFirst() {
        // 键顺序：image → image_url → imageUrl
        let body = #"{"image_url":"https://a.png","image":"https://b.png"}"#
        XCTAssertEqual(extractMetadataImageURLFromBody(body, metadataUri: "https://example.com/meta.json"), "https://b.png")
    }

    func testExtractDataUnwrap() {
        let body = #"{"data":{"name":"avatar","description":"hello","image":"./images/avatar.png"}}"#
        XCTAssertEqual(
            extractMetadataImageURLFromBody(body, metadataUri: "https://example.com/meta.json"),
            "https://example.com/images/avatar.png"
        )
    }

    func testExtractMalformedJsonReturnsNil() {
        XCTAssertNil(extractMetadataImageURLFromBody("not-json", metadataUri: "https://example.com/meta.json"))
        XCTAssertNil(extractMetadataImageURLFromBody(#"{"no_image":true}"#, metadataUri: "https://example.com/meta.json"))
    }

    func testExtractMetadataFields() {
        let body = #"{"data":{"name":"avatar","description":"hello","image":"./images/avatar.png"}}"#
        let fields = extractMetadataFields(body, metadataUri: "https://example.com/meta.json")
        XCTAssertEqual(fields.name, "avatar")
        XCTAssertEqual(fields.description, "hello")
        XCTAssertEqual(fields.image, "https://example.com/images/avatar.png")
    }

    func testExtractMetadataFieldsFailureReturnsEmpty() {
        let fields = extractMetadataFields("not-json", metadataUri: "https://example.com/meta.json")
        XCTAssertNil(fields.image)
        XCTAssertNil(fields.name)
        XCTAssertNil(fields.description)
    }

    // MARK: extractSwtcMetadataUri（hex 向量，对齐 Kotlin 测试）

    func testExtractSwtcMetadataUriDecodesTokenInfos() {
        let payload = """
        [
          {
            "TokenInfo": {
              "InfoType": "746f6b656e557269",
              "InfoData": "697066733a2f2f626166792d746573742f6d6574612e6a736f6e"
            }
          }
        ]
        """
        XCTAssertEqual(parseSwtcMetadataUri(payload), "\(self.defaultGateway)bafy-test/meta.json")
    }

    func testExtractSwtcMetadataUriSkipsNonTokenUri() {
        let payload = """
        [
          { "TokenInfo": { "InfoType": "616263", "InfoData": "68747470733a2f2f782e636f6d2f6d2e6a736f6e" } }
        ]
        """
        XCTAssertNil(parseSwtcMetadataUri(payload))
    }

    func testExtractSwtcMetadataUriHandlesBlank() {
        XCTAssertNil(parseSwtcMetadataUri(nil))
        XCTAssertNil(parseSwtcMetadataUri(""))
        XCTAssertNil(parseSwtcMetadataUri("not-json"))
    }
}
