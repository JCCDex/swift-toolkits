import Foundation
@testable import SwiftDappConnect
import Testing

@Test func `web origin normalizes scheme host and default ports`() {
    #expect(WebOrigin.normalize("https://DApp.Example.com") == "https://dapp.example.com")
    #expect(WebOrigin.normalize("http://example.com") == "http://example.com")
    #expect(WebOrigin.normalize("https://example.com:443") == "https://example.com")
    #expect(WebOrigin.normalize("http://example.com:80") == "http://example.com")
    #expect(WebOrigin.normalize("https://example.com:8443") == "https://example.com:8443")
    #expect(WebOrigin.normalize("https://example.com/path?q=1") == "https://example.com")
}

@Test func `web origin rejects unsafe inputs`() {
    #expect(WebOrigin.normalize("") == nil)
    #expect(WebOrigin.normalize("   ") == nil)
    #expect(WebOrigin.normalize("ftp://example.com") == nil)
    #expect(WebOrigin.normalize("javascript:alert(1)") == nil)
    #expect(WebOrigin.normalize("file:///etc/passwd") == nil)
    #expect(WebOrigin.normalize("https://") == nil)
}

@Test func `wallet internal sentinel is not a grantable origin`() {
    #expect(WebOrigin.walletInternal == "wallet_internal")
    #expect(WebOrigin.normalize(WebOrigin.walletInternal) == nil)
}
