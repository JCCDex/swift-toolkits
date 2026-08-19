@testable import SwiftNft
import XCTest

final class NftUrlUtilsTests: XCTestCase {
    private let defaultGateway = "https://ipfs.jccdex.cn/ipfs/"

    // MARK: normalizeAssetUrl KAT（对齐 Kotlin NftSdkTest）

    func testNormalizeIpfsUriToGateway() {
        XCTAssertEqual(
            normalizeRemoteAssetUrl("ipfs://bafy123/avatar.png"),
            "\(self.defaultGateway)bafy123/avatar.png"
        )
    }

    func testNormalizeSlashIpfsPrefix() {
        XCTAssertEqual(normalizeRemoteAssetUrl("/ipfs/bafy123/avatar.png"), "\(self.defaultGateway)bafy123/avatar.png")
        XCTAssertEqual(normalizeRemoteAssetUrl("ipfs/bafy123/avatar.png"), "\(self.defaultGateway)bafy123/avatar.png")
    }

    func testNormalizeBareCid() {
        XCTAssertEqual(normalizeRemoteAssetUrl("QmHash/avatar.png"), "\(self.defaultGateway)QmHash/avatar.png")
        XCTAssertEqual(normalizeRemoteAssetUrl("bafyHash/meta.json"), "\(self.defaultGateway)bafyHash/meta.json")
    }

    func testNormalizeHttpIpfsPathCanonicalized() {
        XCTAssertEqual(
            normalizeRemoteAssetUrl("https://cdn.thirdparty.com/ipfs/xyz/a.png"),
            "\(self.defaultGateway)xyz/a.png"
        )
    }

    func testNormalizeRelativePathAgainstMetadataUrl() {
        XCTAssertEqual(
            normalizeRemoteAssetUrl("assets/avatar.png", baseUrl: "https://example.com/meta.json"),
            "https://example.com/assets/avatar.png"
        )
    }

    func testNormalizeProtocolRelative() {
        XCTAssertEqual(
            normalizeRemoteAssetUrl("//host/a.png", baseUrl: "https://example.com/meta.json"),
            "https://host/a.png"
        )
    }

    func testNormalizeNoBaseKeepsRawValue() {
        // 对齐 Kotlin：无 base 的不可解析路径返回原样（不判 nil）。
        XCTAssertEqual(normalizeRemoteAssetUrl("not-a-url"), "not-a-url")
    }

    func testNormalizeJsonPayloadReturnsNil() {
        XCTAssertNil(normalizeRemoteAssetUrl(#"{"image":"x"}"#))
        XCTAssertNil(normalizeRemoteAssetUrl(#"["a"]"#))
    }

    func testNormalizeBlankReturnsNil() {
        XCTAssertNil(normalizeRemoteAssetUrl(nil))
        XCTAssertNil(normalizeRemoteAssetUrl("   "))
    }

    func testNormalizeDataUrlPassthrough() {
        let dataURL = "data:image/png;base64,AAAA"
        XCTAssertEqual(normalizeRemoteAssetUrl(dataURL), dataURL)
    }

    func testNormalizeCustomGatewayThreadsThrough() {
        let custom = "https://custom.gateway/ipfs/"
        XCTAssertEqual(
            normalizeRemoteAssetUrl("ipfs://bafy123/a.png", gateway: custom),
            "\(custom)bafy123/a.png"
        )
        XCTAssertEqual(
            normalizeRemoteAssetUrl("https://cdn.x.com/ipfs/xyz", gateway: custom),
            "\(custom)xyz"
        )
    }

    // MARK: isSupportedRemoteAssetUrl

    func testIsLoadableRemoteAssetUrl() {
        XCTAssertTrue(isLoadableRemoteAssetUrl("https://example.com/a.png"))
        XCTAssertTrue(isLoadableRemoteAssetUrl("http://example.com/a.png"))
        XCTAssertTrue(isLoadableRemoteAssetUrl("data:image/png;base64,AAAA"))
        XCTAssertFalse(isLoadableRemoteAssetUrl("ipfs://bafy123/a.png"))
        XCTAssertFalse(isLoadableRemoteAssetUrl(nil))
        XCTAssertFalse(isLoadableRemoteAssetUrl(""))
    }

    func testIsDataImageUrl() {
        XCTAssertTrue(isDataImageUrl("data:image/png;base64,AAAA"))
        XCTAssertTrue(isDataImageUrl("data:image/svg+xml;base64,AAAA"))
        XCTAssertFalse(isDataImageUrl("data:text/html;base64,AAAA"))
        XCTAssertFalse(isDataImageUrl("https://example.com/a.png"))
        XCTAssertFalse(isDataImageUrl(nil))
    }

    // MARK: extractMetadataImageUrlFromBody（原公开 2 参便捷版已并入门面，纯函数走内部版）

    func testExtractResolvedMetadataImageUrl() {
        XCTAssertEqual(
            extractMetadataImageUrlFromBody(#"{"image":"./nft/avatar.png"}"#, metadataUri: "https://example.com/meta.json"),
            "https://example.com/nft/avatar.png"
        )
    }

    func testExtractImageKeyOrderImageFirst() {
        // 键顺序：image → image_url → imageUrl
        let body = #"{"image_url":"https://a.png","image":"https://b.png"}"#
        XCTAssertEqual(extractMetadataImageUrlFromBody(body, metadataUri: "https://example.com/meta.json"), "https://b.png")
    }

    func testExtractDataUnwrap() {
        let body = #"{"data":{"name":"avatar","description":"hello","image":"./images/avatar.png"}}"#
        XCTAssertEqual(
            extractMetadataImageUrlFromBody(body, metadataUri: "https://example.com/meta.json"),
            "https://example.com/images/avatar.png"
        )
    }

    func testExtractMalformedJsonReturnsNil() {
        XCTAssertNil(extractMetadataImageUrlFromBody("not-json", metadataUri: "https://example.com/meta.json"))
        XCTAssertNil(extractMetadataImageUrlFromBody(#"{"no_image":true}"#, metadataUri: "https://example.com/meta.json"))
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
