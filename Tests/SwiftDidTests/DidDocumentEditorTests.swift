@testable import SwiftDid
import XCTest

/// `DidDocumentEditor` 纯函数测试（services/credentials 的读改写，无 I/O）。
final class DidDocumentEditorTests: XCTestCase {

    // MARK: - profileService

    func testProfileServiceBuildsExpectedDict() {
        let service = DidDocumentEditor.profileService(did: "did:swtc:abc", nickname: "alice", preferredAvatar: "vc-1")

        XCTAssertEqual(service["id"] as? String, "did:swtc:abc#profile")
        XCTAssertEqual(service["type"] as? String, "Profile")
        let endpoint = service["serviceEndpoint"] as? [String: Any]
        XCTAssertEqual(endpoint?["nickname"] as? String, "alice")
        XCTAssertEqual(endpoint?["preferredAvatar"] as? String, "vc-1")
        // 对齐 Kotlin 写入形态：只保留 id/type/serviceEndpoint 三键
        XCTAssertEqual(service.count, 3)
    }

    func testProfileServiceAllowsEmptyFields() {
        let service = DidDocumentEditor.profileService(did: "did:ethr:0x1", nickname: "", preferredAvatar: "")
        let endpoint = service["serviceEndpoint"] as? [String: Any]
        XCTAssertEqual(endpoint?["nickname"] as? String, "")
        XCTAssertEqual(endpoint?["preferredAvatar"] as? String, "")
    }

    // MARK: - ipfsStorageService

    func testIpfsStorageServiceSetsPreviousCidAndPreservesEndpoint() {
        let service: [String: Any] = [
            "id": "did:swtc:abc#ipfs-storage",
            "type": "IpfsStorage",
            "serviceEndpoint": ["ipns": "ipns://x", "custom": "y"]
        ]
        let rebuilt = DidDocumentEditor.ipfsStorageService(did: "did:swtc:abc", from: service, previousCid: "cid-1")

        XCTAssertEqual(rebuilt["id"] as? String, "did:swtc:abc#ipfs-storage")
        XCTAssertEqual(rebuilt["type"] as? String, "IpfsStorage")
        let endpoint = rebuilt["serviceEndpoint"] as? [String: Any]
        XCTAssertEqual(endpoint?["previousCid"] as? String, "cid-1")
        XCTAssertEqual(endpoint?["ipns"] as? String, "ipns://x", "原 endpoint 键应保留")
        XCTAssertEqual(endpoint?["custom"] as? String, "y")
    }

    func testIpfsStorageServiceSkipsBlankPreviousCid() {
        let service: [String: Any] = ["serviceEndpoint": ["ipns": "ipns://x"]]
        let rebuilt = DidDocumentEditor.ipfsStorageService(did: "did:swtc:abc", from: service, previousCid: "")
        let endpoint = rebuilt["serviceEndpoint"] as? [String: Any]
        XCTAssertNil(endpoint?["previousCid"], "空 previousCid 不应写入")
        XCTAssertEqual(endpoint?["ipns"] as? String, "ipns://x")
    }

    func testIpfsStorageServiceSkipsNilPreviousCid() {
        let service: [String: Any] = ["serviceEndpoint": [:]]
        let rebuilt = DidDocumentEditor.ipfsStorageService(did: "did:swtc:abc", from: service, previousCid: nil)
        let endpoint = rebuilt["serviceEndpoint"] as? [String: Any]
        XCTAssertNil(endpoint?["previousCid"])
    }

    func testIpfsStorageServiceDefaultsIdWhenMissing() {
        let service: [String: Any] = ["serviceEndpoint": [:]]
        let rebuilt = DidDocumentEditor.ipfsStorageService(did: "did:ethr:0x1", from: service, previousCid: nil)
        XCTAssertEqual(rebuilt["id"] as? String, "did:ethr:0x1#ipfs-storage")
    }

    // MARK: - services(from:) / setServices

    func testServicesReadsSingularOrPluralOrMissing() {
        XCTAssertEqual(DidDocumentEditor.services(from: ["service": [["type": "Profile"]]]).count, 1)
        XCTAssertEqual(DidDocumentEditor.services(from: ["services": [["type": "Profile"]]]).count, 1)
        XCTAssertEqual(DidDocumentEditor.services(from: [:]).count, 0)
    }

    func testSetServicesReplacesPluralKey() {
        var json: [String: Any] = ["services": [["type": "old"]], "other": 1]
        DidDocumentEditor.setServices([["type": "Profile"]], on: &json)

        XCTAssertNil(json["services"], "旧 services 键应删除，避免双键漂移")
        XCTAssertEqual((json["service"] as? [Any])?.count, 1)
        XCTAssertEqual(json["other"] as? Int, 1, "无关键应保留")
    }

    // MARK: - credentials(from:)

    func testCredentialsReadsSingularOrPluralOrMissing() {
        XCTAssertEqual(DidDocumentEditor.credentials(from: ["credentials": [["id": "a"]]]).count, 1)
        XCTAssertEqual(DidDocumentEditor.credentials(from: ["credential": [["id": "b"]]]).count, 1)
        XCTAssertEqual(DidDocumentEditor.credentials(from: [:]).count, 0)
    }

    // MARK: - upsertCredential

    func testUpsertCredentialReplacesByCaseInsensitiveId() {
        let credentials: [Any] = [
            ["id": "VC-A", "value": "old"],
            ["id": "VC-B", "value": "keep"]
        ]
        let incoming: [String: Any] = ["id": "vc-a", "value": "new"]

        let result = DidDocumentEditor.upsertCredential(credentials, incoming: incoming, byId: "vc-a")

        XCTAssertEqual(result.count, 2, "替换不应增删元素")
        XCTAssertEqual((result[0] as? [String: Any])?["value"] as? String, "new")
        XCTAssertEqual((result[1] as? [String: Any])?["id"] as? String, "VC-B")
    }

    func testUpsertCredentialAppendsWhenNoMatch() {
        let credentials: [Any] = [["id": "VC-B", "value": "keep"]]
        let incoming: [String: Any] = ["id": "vc-a", "value": "new"]

        let result = DidDocumentEditor.upsertCredential(credentials, incoming: incoming, byId: "vc-a")

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual((result.last as? [String: Any])?["id"] as? String, "vc-a")
    }

    func testUpsertCredentialIgnoresNonDictElements() {
        let credentials: [Any] = ["not-a-dict", ["id": "VC-B", "value": "keep"]]
        let incoming: [String: Any] = ["id": "vc-a", "value": "new"]

        let result = DidDocumentEditor.upsertCredential(credentials, incoming: incoming, byId: "vc-a")

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0] as? String, "not-a-dict", "非字典元素应原样保留")
        XCTAssertEqual((result.last as? [String: Any])?["id"] as? String, "vc-a")
    }

    // MARK: - removingCredential

    func testRemovingCredentialRemovesByCaseInsensitiveId() {
        let credentials: [Any] = [
            ["id": "VC-A", "value": "a"],
            ["id": "VC-B", "value": "b"]
        ]
        let result = DidDocumentEditor.removingCredential(credentials, byId: "vc-a")

        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual((result?.first as? [String: Any])?["id"] as? String, "VC-B")
    }

    func testRemovingCredentialReturnsNilWhenNoMatch() {
        let credentials: [Any] = [["id": "VC-B", "value": "b"]]
        XCTAssertNil(DidDocumentEditor.removingCredential(credentials, byId: "nope"))
    }
}
