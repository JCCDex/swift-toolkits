@testable import SwiftNft
import XCTest

/// 镜像 Kotlin `NftRemoteAssetResolverTest`（SsrfGuard 全边界）+ Swift 修正（全地址解析、IPv4-mapped、ULA/CGNAT）。
final class SsrfGuardTests: XCTestCase {
    override func tearDown() {
        SsrfGuard.enabled = true
    }

    private func check(_ url: String) -> Bool {
        guard let url = URL(string: url) else { return false }
        return SsrfGuard.check(url)
    }

    // MARK: 私网/回环/链路本地拒绝

    func testRejectsLoopback() {
        XCTAssertFalse(self.check("http://127.0.0.1:8080/metadata"))
        XCTAssertFalse(self.check("http://localhost/metadata"))
    }

    func testRejectsSiteLocal() {
        XCTAssertFalse(self.check("http://10.0.0.1/metadata"))
        XCTAssertFalse(self.check("http://192.168.1.1/metadata"))
        XCTAssertFalse(self.check("http://172.16.0.1/metadata"))
    }

    func testRejectsLinkLocal() {
        XCTAssertFalse(self.check("http://169.254.1.1/metadata"))
    }

    func testRejectsCGNAT() {
        XCTAssertFalse(self.check("http://100.64.0.1/metadata"))
        XCTAssertFalse(self.check("http://100.127.255.254/metadata"))
    }

    func testRejectsZeroAndBroadcast() {
        XCTAssertFalse(self.check("http://0.0.0.0/metadata"))
        XCTAssertFalse(self.check("http://255.255.255.255/metadata"))
    }

    // MARK: 公网放行（对齐 Kotlin 测试）

    func testAllowsPublicIPv4() {
        XCTAssertTrue(self.check("https://8.8.8.8/metadata.json"))
        XCTAssertTrue(self.check("https://1.1.1.1/ipfs/QmExample"))
    }

    func testAllowsPublicIPv6() {
        XCTAssertTrue(self.check("https://[2606:4700:4700::1111]/metadata.json"))
    }

    // MARK: scheme 白名单

    func testRejectsNonHttpScheme() {
        XCTAssertFalse(self.check("file:///etc/passwd"))
        XCTAssertFalse(self.check("javascript:alert(1)"))
        XCTAssertFalse(self.check("ftp://example.com/metadata"))
        XCTAssertFalse(self.check("ipfs://QmExample"))
    }

    // MARK: 畸形/空

    func testRejectsMalformed() {
        XCTAssertFalse(self.check("not-a-url"))
        XCTAssertFalse(self.check(""))
    }

    // MARK: 未解析域名 fail-closed

    func testRejectsUnresolvedHostFailClosed() {
        XCTAssertFalse(self.check("http://this-host-should-not-resolve.invalid/metadata"))
    }

    // MARK: IPv6 地址段（Swift 增强，对齐 Nft-Swift 02 §4）

    func testRejectsIPv6LoopbackAndUnspecified() {
        XCTAssertFalse(self.check("http://[::1]/metadata"))
        XCTAssertFalse(self.check("http://[::]/metadata"))
    }

    func testRejectsIPv6MappedPrivate() {
        XCTAssertFalse(self.check("http://[::ffff:127.0.0.1]/metadata"))
        XCTAssertFalse(self.check("http://[::ffff:192.168.1.1]/metadata"))
    }

    func testAllowsIPv6MappedPublic() {
        XCTAssertTrue(self.check("http://[::ffff:8.8.8.8]/metadata"))
    }

    func testRejectsIPv6LinkLocalSiteLocalAndULA() {
        XCTAssertFalse(self.check("http://[fe80::1]/metadata"))
        XCTAssertFalse(self.check("http://[fec0::1]/metadata"))
        XCTAssertFalse(self.check("http://[fc00::1]/metadata"))
        XCTAssertFalse(self.check("http://[fd00::1]/metadata"))
    }

    // MARK: 测试旁路开关（对齐 Kotlin enabled=false）

    func testAllowsAllWhenDisabled() {
        SsrfGuard.enabled = false
        XCTAssertTrue(self.check("http://127.0.0.1/metadata"))
        XCTAssertTrue(self.check("http://192.168.1.1/metadata"))
        XCTAssertTrue(self.check("https://example.com/metadata"))
    }
}
