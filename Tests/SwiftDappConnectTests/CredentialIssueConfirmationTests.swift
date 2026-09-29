import Foundation
@testable import SwiftDappConnect
import Testing

/// **E7(iOS 半部)** —— 与 Android/Kotlin 对齐:`did_issueCredential` 必须经**宿主确认**才签名。
///
/// 对齐点:①钩子只收 `payload`(同 Kotlin `didCredentialConfirm`);②未注入 → **fail-closed 拒签**;
/// ③拒绝 → EIP-1193 **4001**;④**顺序 = 先取钥(触发宿主签名认证/密码)→ 再确认 → 再签名**。
@MainActor
private final class FakeDidSDK: DidSDK {
    var signedPayloads: [String] = []

    func didGenerateBase58PublicKey(privateKey: String) async throws -> (publicKeyBase58: String, type: String) {
        ("pk", "type")
    }

    func signCredential(privateKey: String, vcJson: String) async throws -> String {
        signedPayloads.append(vcJson)
        return #"{"id":"did:swtc:owner#vc-1"}"#
    }

    func ipfsPersonalSign(privateKey: String, data: [Int]) async throws -> String { "sig" }

    func ipfsGetPublicKey(privateKey: String) async throws -> String { "pk" }
}

@MainActor
private func makeInterface(
    didSDK: DidSDK?,
    privateKey: String?,
    confirm: DidCredentialConfirmCallback?
) -> WebAppInterface {
    WebAppInterface(
        ethMiddleware: FakeEthMiddleware(),
        swtcMiddleware: FakeSwtcMiddleware(),
        secretProvider: FakeSecretProvider(privateKey: privateKey),
        didSDK: didSDK,
        didCredentialConfirm: confirm
    )
}

private func issueRequest() -> DAppRequest {
    DAppRequest(
        name: "did_issueCredential",
        network: "eth",
        id: "1",
        nonce: "nonce-1",
        params: [
            [
                "keyDoc": ["address": "0xabc", "did": "did:ethr:0xabc", "id": "key-1"],
                "credential": ["type": ["VerifiableCredential"]]
            ]
        ]
    )
}

private func errorPayload(_ payload: [String: Any]) -> (code: Int?, message: String?) {
    let error = payload["error"] as? [String: Any]
    return (error?["code"] as? Int, error?["message"] as? String)
}

@Test @MainActor func `no confirmation callback means the credential is not signed`() async {
    let did = FakeDidSDK()
    let payload =
        await makeInterface(didSDK: did, privateKey: "key", confirm: nil)
            .route(issueRequest(), origin: "https://dapp.com")
    let (code, message) = errorPayload(payload)
    #expect(code == -1)
    #expect(message == "Credential signing requires host confirmation")
    #expect(did.signedPayloads.isEmpty)
}

@Test @MainActor func `host rejection maps to 4001 and skips signing`() async {
    let did = FakeDidSDK()
    var seen: [String] = []
    let payload =
        await makeInterface(didSDK: did, privateKey: "key", confirm: { p in
            seen.append(p)
            return false
        })
        .route(issueRequest(), origin: "https://dapp.com")
    let (code, message) = errorPayload(payload)
    #expect(code == 4001, "用户拒绝按 EIP-1193 4001 返回")
    #expect(message == "Credential signing was rejected")
    #expect(seen.count == 1, "确认回调必须收到待签 payload")
    #expect(did.signedPayloads.isEmpty)
}

@Test @MainActor func `host approval reaches the signature`() async {
    let did = FakeDidSDK()
    var calls = 0
    let payload =
        await makeInterface(didSDK: did, privateKey: "key", confirm: { _ in
            calls += 1
            return true
        })
        .route(issueRequest(), origin: "https://dapp.com")
    #expect(calls == 1)
    #expect(did.signedPayloads.count == 1)
    #expect((payload["result"] as? [String: Any])?["id"] as? String == "did:swtc:owner#vc-1")
}

@Test @MainActor func `the key is fetched before the user is asked`() async {
    let did = FakeDidSDK()
    var calls = 0
    let payload =
        await makeInterface(didSDK: did, privateKey: nil, confirm: { _ in
            calls += 1
            return true
        })
        .route(issueRequest(), origin: "https://dapp.com")
    #expect(errorPayload(payload).code == -1, "取不到私钥时按错误返回")
    #expect(calls == 0, "顺序必须是先取钥、后确认(与 Kotlin 对齐):取钥失败时不应打扰用户")
    #expect(did.signedPayloads.isEmpty)
}
