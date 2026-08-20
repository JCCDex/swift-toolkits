import Foundation
@testable import SwiftNft
import XCTest

/// SwtcTokenUriResolver / EthTokenUriResolver 网络路径测试（URLProtocol 桩，不联网）：
/// - SwtcTokenUriResolver：`getRpcNode` 单节点注入 + `NftHttpClient.fetchRpc`、真实 erc_info 响应形状（TokenInfos 数组/字符串）、
///   RPC error、响应超限、空 tokenId、节点 nil；
/// - EthTokenUriResolver：eth_call 成功解码（真实 ABI 形状）、revert（无 result）、
///   getRpcNode 返回 nil、非法 calldata。
final class NetClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        self.session = URLSession(configuration: configuration)
        SsrfGuard.enabled = false
    }

    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        StubURLProtocol.capturedRequests = []
        self.session = nil
        SsrfGuard.enabled = true
    }

    // MARK: - SwtcTokenUriResolver

    func testSwtcTokenUriResolverFetchesMetadataUriFromGetRpcNode() async {
        // 真实响应（demo 使用的节点 https://srje115qd43qw2.swtc.top 实际返回，2026-08-20）：
        // TokenInfos 数组、InfoType hex 746F6B656E557269（"tokenUri"）、InfoData hex 真实元数据 URI。
        let body = self.fixture("erc_info_nft8")
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://rpc.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = SwtcTokenUriResolver(getRpcNode: { "https://rpc.test" }, httpClient: URLSessionNftHttpClient(session: self.session))
        let result = await client.fetchMetadataUri(tokenId: "43726F737320436861696E2044414F2000000000000000000000000000000008")
        XCTAssertEqual(result, "https://ipfs.jccdex.cn/ipfs/bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8")
    }

    func testSwtcTokenUriResolverParsesStringTokenInfos() async {
        // TokenInfos 可能是字符串（真实链上两种形态之一）
        let uri = "ipfs://bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8"
        let body = """
        {"result":{"TokenInfo":{"TokenInfos":"[{\\"TokenInfo\\":{\\"InfoType\\":\\"\(Self.hex("tokenUri"))\\",\\"InfoData\\":\\"\(Self.hex(uri))\\"}}]"}}}
        """
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://rpc.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = SwtcTokenUriResolver(getRpcNode: { "https://rpc.test" }, httpClient: URLSessionNftHttpClient(session: self.session))
        let result = await client.fetchMetadataUri(tokenId: "1")
        XCTAssertEqual(result, "https://ipfs.jccdex.cn/ipfs/bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/8")
    }

    func testSwtcTokenUriResolverReturnsNilOnRpcError() async {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"err"}}"#
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://rpc.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = SwtcTokenUriResolver(getRpcNode: { "https://rpc.test" }, httpClient: URLSessionNftHttpClient(session: self.session))
        let result = await client.fetchMetadataUri(tokenId: "1")
        XCTAssertNil(result)
    }

    func testSwtcTokenUriResolverReturnsNilWhenGetRpcNodeNil() async {
        let client = SwtcTokenUriResolver(getRpcNode: { nil }, httpClient: URLSessionNftHttpClient(session: self.session))
        let noNode = await client.fetchMetadataUri(tokenId: "1")
        XCTAssertNil(noNode, "无节点 → nil，不发起请求")
        let blank = await client.fetchMetadataUri(tokenId: "  ")
        XCTAssertNil(blank, "空白 tokenId → nil")
    }

    func testSwtcTokenUriResolverRejectsOversizedResponse() async {
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://rpc.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(String(repeating: "x", count: 10000).utf8))
        }
        let client = SwtcTokenUriResolver(getRpcNode: { "https://rpc.test" }, httpClient: URLSessionNftHttpClient(session: self.session, maxBodyBytes: 1024))
        let result = await client.fetchMetadataUri(tokenId: "1")
        XCTAssertNil(result)
    }

    // MARK: - EthTokenUriResolver（eth_call 走 URLSession.shared + URLProtocol 全局注册）

    func testResolveEthrTokenUriDecodesRealAbiString() async {
        // 真实响应（demo 使用的节点 https://ethereum-rpc.publicnode.com 实际 eth_call 返回，2026-08-20）：
        // tokenURI(0x5B5b…/4) = "ipfs://bafybei…ux4y/4"（offset=0x20 + length=0x44 + utf8 + 32 字节字对齐）
        let body = self.fixture("eth_call_tokenuri4")
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://rpc.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let resolver = EthTokenUriResolver(
            getRpcNode: { $0 == 1 ? "https://rpc.test" : nil },
            httpClient: URLSessionNftHttpClient(session: self.session)
        )
        let result = await resolver.resolveEthrTokenUri(
            contract: "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a",
            tokenId: "4",
            chainId: 1
        )
        XCTAssertEqual(result, "https://ipfs.jccdex.cn/ipfs/bafybeidymecalbda5mlmgrhxwfubr7mlojlf7wjdzy5rnv7qsy76zmux4y/4")

        // 校验真实请求：calldata = selector 0xc87b56dd + 32 字节十进制 tokenId；合约地址走 to 字段，不进 calldata
        guard let captured = StubURLProtocol.capturedRequests.last,
              let callJson = Self.bodyData(from: captured).flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }),
              let call = (callJson["params"] as? [Any])?.first as? [String: Any]
        else {
            return XCTFail("未捕获 eth_call 请求")
        }
        XCTAssertEqual(call["to"] as? String, "0x5B5b422A4fEd431882606E7b0D6abb0ba84bDA3a")
        XCTAssertEqual(call["data"] as? String, "0xc87b56dd" + String(repeating: "0", count: 63) + "4")
    }

    func testResolveEthrTokenUriReturnsNilOnRevert() async {
        // tokenURI revert：无 result 字段（真实场景：0x7e273289 ERC721NonexistentToken）
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":3,"message":"execution reverted"}}"#
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://rpc.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let resolver = EthTokenUriResolver(
            getRpcNode: { _ in "https://rpc.test" },
            httpClient: URLSessionNftHttpClient(session: self.session)
        )
        let result = await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "4", chainId: 1)
        XCTAssertNil(result)
    }

    func testResolveEthrTokenUriReturnsNilWithoutRpcNode() async {
        let resolver = EthTokenUriResolver(getRpcNode: { _ in nil })
        let result = await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "4", chainId: 1)
        XCTAssertNil(result, "getRpcNode 返回 nil → 不发起请求")
    }

    func testResolveEthrTokenUriReturnsNilForInvalidTokenId() async {
        let resolver = EthTokenUriResolver(
            getRpcNode: { _ in "https://rpc.test" },
            httpClient: URLSessionNftHttpClient(session: self.session)
        )
        let result = await resolver.resolveEthrTokenUri(contract: "0xabc", tokenId: "not-a-number", chainId: 1)
        XCTAssertNil(result, "非法 tokenId → calldata 构造失败 → nil")
    }

    // MARK: - 工具

    /// URLProtocol 层拿不到 `httpBody`（被 URLSession 转成 bodyStream），须从流读取。
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// 加载真实响应 fixture（`.copy("Fixtures")` 保留目录层级，需 subdirectory 参数）。
    private func fixture(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            XCTFail("fixture 缺失: \(name).json")
            return ""
        }
        return content
    }
}
