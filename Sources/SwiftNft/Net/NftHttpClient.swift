import Foundation

/// HTTP 拉取抽象（可注入 Fake；URLProtocol 可整体 stub）。行为对齐 Kotlin `fetchJson`/`fetchText`：
/// - **不跟随重定向**（Kotlin `instanceFollowRedirects = false`）——该 SDK 已无 `httpShouldFollowRedirects`，
///   用 delegate-backed session 在 `willPerformHTTPRedirection` 返回 nil（**勿用 `URLSession.shared`**，
///   无 delegate 会静默跟随；重定向是 SSRF 绕过路径，见 Nft-Swift 02 §4/§8）；
/// - 10s 超时（`URLRequest.timeoutInterval` ≈ 空闲超时，近似 Kotlin `readTimeout`；`connectTimeout`
///   在 URLSession 无直接等价）；
/// - 2xx 且 body 非空才成功；2 MiB 响应体上限（Swift 增强，防膨胀）；
/// - SSRF 拒绝（`SsrfGuard` 校验失败）→ 返回 nil（同 Kotlin fetch 前 check）。
/// 仅传输级错误（URLError 等）throw；其余失败统一 nil。
public protocol NftHttpClient: Sendable {
    /// GET JSON 元数据原始 body（**不做解析校验**；解析由门面完成一次——客户端校验会与门面重复解析）。
    func fetchJson(_ url: URL) async throws -> Data?
    /// GET 文本 body。
    func fetchText(_ url: URL) async throws -> String?
}

public struct URLSessionNftHttpClient: NftHttpClient {
    public let session: URLSession
    public let timeout: TimeInterval
    public let maxBodyBytes: Int

    private let delegate: NoRedirectDelegate?

    public init(
        session: URLSession? = nil,
        timeout: TimeInterval = 10,
        maxBodyBytes: Int = 2 * 1024 * 1024
    ) {
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
        if let session {
            // ⚠️ 注入自定义 session 时，调用方必须保证其**不跟随重定向**（delegate 随 session 固定，
            // 无法挂上 NoRedirectDelegate）——否则重定向是 SSRF 绕过路径（勿传 URLSession.shared）。
            self.session = session
            self.delegate = nil
        } else {
            let delegate = NoRedirectDelegate()
            self.delegate = delegate
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    public func fetchJson(_ url: URL) async throws -> Data? {
        try await self.fetchData(url)
    }

    public func fetchText(_ url: URL) async throws -> String? {
        guard let data = try await fetchData(url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func fetchData(_ url: URL) async throws -> Data? {
        #if DEBUG
            if !SsrfGuard.enabled { /* 测试旁路：跳过 check（对齐 Kotlin enabled=false） */ }
            else if !SsrfGuard.check(url) {
                return nil
            }
        #else
            if !SsrfGuard.check(url) {
                return nil
            }
        #endif

        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
        guard !data.isEmpty, data.count <= self.maxBodyBytes else { return nil }
        return data
    }
}

/// 不跟随重定向的 delegate（`willPerformHTTPRedirection` → completionHandler(nil)）。
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
