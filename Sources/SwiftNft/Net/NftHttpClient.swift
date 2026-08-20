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
    /// JSON-RPC POST（`eth_call` / SWTC `erc_info`）：RPC 节点可信、**跟随重定向**
    /// （对齐 Kotlin `instanceFollowRedirects = true`，与 GET 拉取的 no-redirect 相反）；
    /// 其余行为同 `fetchJson`（2xx + body 非空 + 2 MiB 上限 + `SsrfGuard` 建连检查）。
    func fetchRpc(_ url: URL, body: Data) async throws -> Data?
}

public struct URLSessionNftHttpClient: NftHttpClient {
    public let session: URLSession
    public let timeout: TimeInterval
    public let maxBodyBytes: Int

    private let delegate: NoRedirectDelegate?
    /// RPC 专用 session：**跟随重定向**（无 delegate；对齐 Kotlin `instanceFollowRedirects = true`）。
    private let rpcSession: URLSession

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
            // RPC 请求同样走注入 session（测试注入 URLProtocol 桩 session；真实场景勿用 shared）。
            self.session = session
            self.rpcSession = session
            self.delegate = nil
        } else {
            let delegate = NoRedirectDelegate()
            self.delegate = delegate
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            // RPC：跟随重定向（无 delegate），节点可信
            let rpcConfiguration = URLSessionConfiguration.default
            rpcConfiguration.timeoutIntervalForRequest = timeout
            self.rpcSession = URLSession(configuration: rpcConfiguration)
        }
    }

    public func fetchJson(_ url: URL) async throws -> Data? {
        try await self.fetchData(url, session: self.session)
    }

    public func fetchText(_ url: URL) async throws -> String? {
        guard let data = try await fetchData(url, session: self.session) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func fetchRpc(_ url: URL, body: Data) async throws -> Data? {
        guard Self.ssrfAllowed(url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await self.fetchData(request, session: self.rpcSession)
    }

    private func fetchData(_ url: URL, session: URLSession) async throws -> Data? {
        guard Self.ssrfAllowed(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        return try await self.fetchData(request, session: session)
    }

    /// SSRF 建连检查（`SsrfGuard.enabled = false` 测试旁路，对齐 Kotlin enabled=false）。
    private static func ssrfAllowed(_ url: URL) -> Bool {
        #if DEBUG
            if !SsrfGuard.enabled {
                return true
            }
        #endif
        return SsrfGuard.check(url)
    }

    /// 流式读取 + 硬上限：超过 maxBodyBytes 即中止（for-await 提前退出会取消底层 task），
    /// 避免 data(for:) 先全量缓冲进内存、再检查 size 的「下载期内存不受限」问题。
    private func fetchData(_ request: URLRequest, session: URLSession) async throws -> Data? {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
        var data = Data()
        data.reserveCapacity(min(self.maxBodyBytes, 64 * 1024))
        for try await byte in bytes {
            if data.count >= self.maxBodyBytes {
                return nil // 超限即中止
            }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
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
