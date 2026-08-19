import CryptoKit
import Foundation
import Security

/// SWTC 链上元数据 URI 拉取抽象（可注入 Fake；对齐 Kotlin 构造函数注入 `swtcChainNftClient`）。
public protocol SwtcMetadataUriFetching: Sendable {
    func fetchMetadataUri(tokenId: String) async -> String?
}

/// SWTC `erc_info` RPC 客户端（对齐 Kotlin `SwtcChainNftClient`）：
/// - POST `{"method":"erc_info","params":[{"tokenid": tokenId}]}`，rpcNodes 逐个尝试、首个成功即返回；
/// - 15s 超时；**RPC 节点可信可跟随重定向，但重定向目标必须过 `SsrfGuard`**（否则注入节点 302 到私网即绕过）；
/// - 建连前对注入节点做 `SsrfGuard.check`（http/https + 公网）——Swift 可注入，信任边界比 Kotlin 大；
/// - 可选证书 pinning（SHA-256/Base64，`sha256/...` 格式）。
public struct SwtcChainNftClient: SwtcMetadataUriFetching {
    public static let defaultRpcNodes = ["https://srje115qd43qw2.swtc.top"]

    public var rpcNodes: [String]
    public var certificatePins: [String]
    public let timeout: TimeInterval

    private let session: URLSession
    private let delegate: SwtcURLSessionDelegate

    public init(
        rpcNodes: [String] = SwtcChainNftClient.defaultRpcNodes,
        certificatePins: [String] = [],
        timeout: TimeInterval = 15,
        session: URLSession? = nil
    ) {
        self.rpcNodes = rpcNodes
        self.certificatePins = certificatePins
        self.timeout = timeout
        let delegate = SwtcURLSessionDelegate(certificatePins: certificatePins)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        self.session = session ?? URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func fetchMetadataUri(tokenId: String) async -> String? {
        let normalized = tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        for nodeUrl in self.rpcNodes {
            if let uri = await requestErcInfoMetadataUri(nodeUrl: nodeUrl, tokenId: normalized) {
                return uri
            }
        }
        return nil
    }

    private func requestErcInfoMetadataUri(nodeUrl: String, tokenId: String) async -> String? {
        guard let url = URL(string: nodeUrl), SsrfGuard.check(url) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["method": "erc_info", "params": [["tokenid": tokenId]]]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode), !data.isEmpty else { return nil }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            if json["error"] != nil {
                return nil
            }
            return Self.parseErcInfoMetadataUri(json)
        } catch {
            return nil
        }
    }

    /// 响应解析：`result.TokenInfo.TokenInfos`（JSONArray 或字符串）→ `extractSwtcMetadataUri`。
    static func parseErcInfoMetadataUri(_ response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              let tokenInfo = result["TokenInfo"] as? [String: Any],
              let tokenInfos = tokenInfo["TokenInfos"]
        else { return nil }

        let tokenInfosJson: String = if let array = tokenInfos as? [Any] {
            Self.jsonString(array) ?? ""
        } else if let string = tokenInfos as? String, !string.isEmpty {
            string
        } else {
            Self.jsonString(tokenInfos) ?? ""
        }
        return parseSwtcMetadataUri(tokenInfosJson)
    }

    private static func jsonString(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - 重定向守卫 + 可选 pinning delegate

/// RPC 专属 delegate：
/// - `willPerformHTTPRedirection`：对重定向目标再查 `SsrfGuard`，失败即不跟随（防 302 到私网）；
/// - `didReceive challenge`：`certificatePins` 非空时做 SHA-256 公钥 pinning，空时默认处理。
final class SwtcURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let certificatePins: [String]

    init(certificatePins: [String]) {
        self.certificatePins = certificatePins
    }

    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, SsrfGuard.check(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }

    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard !self.certificatePins.isEmpty, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return (.cancelAuthenticationChallenge, nil)
        }
        for certificate in chain {
            guard let key = SecCertificateCopyKey(certificate),
                  let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
            else { continue }
            let digest = SHA256.hash(data: keyData)
            let pin = "sha256/" + Data(digest).base64EncodedString()
            if self.certificatePins.contains(pin) {
                return (.useCredential, URLCredential(trust: trust))
            }
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
