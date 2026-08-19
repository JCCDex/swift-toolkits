import Foundation
@testable import SwiftNft
import XCTest

/// NftHttpClient 行为测试（URLProtocol 桩，不联网）：
/// 流式读取 + `maxBodyBytes` 硬上限、空 body、fetchJson 返回原始 Data（不做 JSON 校验）。
final class NftHttpClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        self.session = URLSession(configuration: configuration)
        // URLProtocol 桩场景不联网：禁用 SsrfGuard（避免对 example.com 的真实 DNS 解析受环境限制 fail-closed）
        SsrfGuard.enabled = false
    }

    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        self.session = nil
        SsrfGuard.enabled = true
    }

    func testFetchTextReturnsBodyWithinLimit() async throws {
        let body = String(repeating: "a", count: 100)
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://example.com/meta.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = URLSessionNftHttpClient(session: session, maxBodyBytes: 1024)
        let result = try await client.fetchText(XCTUnwrap(URL(string: "https://example.com/meta.json")))
        XCTAssertEqual(result, body)
    }

    func testFetchTextReturnsNilWhenBodyExceedsLimit() async throws {
        let body = String(repeating: "a", count: 10000)
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://example.com/meta.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = URLSessionNftHttpClient(session: session, maxBodyBytes: 1024)
        let result = try await client.fetchText(XCTUnwrap(URL(string: "https://example.com/meta.json")))
        XCTAssertNil(result, "超过 maxBodyBytes 必须中止（流式读取在下载期拦截，不整包缓冲）")
    }

    func testFetchTextReturnsNilForEmptyBody() async throws {
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://example.com/meta.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = URLSessionNftHttpClient(session: session)
        let result = try await client.fetchText(XCTUnwrap(URL(string: "https://example.com/meta.json")))
        XCTAssertNil(result, "2xx 但 body 为空 → nil（对齐 Kotlin）")
    }

    func testFetchTextReturnsNilForNon2xx() async throws {
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://example.com/meta.json")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("oops".utf8))
        }
        let client = URLSessionNftHttpClient(session: session)
        let result = try await client.fetchText(XCTUnwrap(URL(string: "https://example.com/meta.json")))
        XCTAssertNil(result)
    }

    func testFetchJsonReturnsRawDataWithoutValidation() async throws {
        // 实现偏离（见 02 §4）：fetchJson 不做 JSON 校验、返回原始 body，解析收敛到门面。
        let body = #"{"image":"https://example.com/a.png"}"#
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://example.com/meta.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = URLSessionNftHttpClient(session: session)
        let result = try await client.fetchJson(XCTUnwrap(URL(string: "https://example.com/meta.json")))
        XCTAssertEqual(result, Data(body.utf8))
    }

    func testSwtcNftClientRejectsOversizedRpcResponse() async {
        // RPC 响应体上限（post-download 检查）：恶意/被黑节点超大响应 → nil。
        SsrfGuard.enabled = false
        defer { SsrfGuard.enabled = true }
        let body = String(repeating: "x", count: 10000)
        StubURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://rpc.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = SwtcNftClient(rpcNodes: ["https://rpc.test"], maxBodyBytes: 1024, session: session)
        let uri = await client.fetchMetadataUri(tokenId: "1")
        XCTAssertNil(uri, "超过 maxBodyBytes 的 RPC 响应拒绝解析")
    }
}

/// URLProtocol 桩：按 `requestHandler` 返回固定响应（不联网）。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
