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
    /// JSON-RPC POST（`eth_call` / SWTC `erc_info`）：RPC 节点**可信、属宿主注入信任面**
    /// （`getRpcNode` 提供），**不做 SsrfGuard 建连检查**（避免误拦本地/私有链节点；
    /// 重定向目标亦不在 SsrfGuard 覆盖内——由宿主保证节点可信）；
    /// **跟随重定向**（对齐 Kotlin `instanceFollowRedirects = true`，与 GET 拉取的 no-redirect 相反）；
    /// 其余行为同 `fetchJson`（2xx + body 非空 + 2 MiB 上限）。
    func fetchRpc(_ url: URL, body: Data) async throws -> Data?
}

public struct URLSessionNftHttpClient: NftHttpClient {
    public let session: URLSession
    public let timeout: TimeInterval
    public let maxBodyBytes: Int

    /// 重定向策略 delegate（随 session 固定，无法 per-request 挂载——由「HTTP 方法」区分策略）。
    private let delegate: RedirectPolicyDelegate

    public init(
        session: URLSession? = nil,
        timeout: TimeInterval = 10,
        maxBodyBytes: Int = 2 * 1024 * 1024
    ) {
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
        if let session {
            // ⚠️ 注入自定义 session 时，调用方必须保证其**不跟随重定向**（delegate 随 session 固定，
            // 无法挂上重定向策略 delegate）——否则重定向是 SSRF 绕过路径（勿传 URLSession.shared）。
            // RPC 请求同样走注入 session（测试注入 URLProtocol 桩 session；真实场景勿用 shared）。
            self.session = session
            self.delegate = RedirectPolicyDelegate()
        } else {
            let delegate = RedirectPolicyDelegate()
            self.delegate = delegate
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            // 单 session（原 GET/RPC 双 session，见 review SwiftNft 补充细节）：
            // 重定向策略由 delegate 按请求方法区分——POST（RPC）跟随、其余（GET 元数据）拒绝。
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // RPC 节点可信：跟随重定向（delegate 按 POST 放行，对齐 Kotlin instanceFollowRedirects=true）
        return try await self.fetchData(request, session: self.session)
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
    ///
    /// GET 禁重定向仅对默认 client 生效（RedirectPolicyDelegate 按方法区分）；注入的自定义
    /// session 无法在库内强制（无 request 级开关，delegate 随 session 固定）——调用方必须用
    /// `URLSessionConfiguration.httpShouldFollowRedirects = false` 的配置构建注入 session
    /// （见 review P1#2：重定向是 SSRF 绕过路径）。
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

/// 重定向策略 delegate（`willPerformHTTPRedirection` 按请求方法决定）：
/// - POST（RPC 节点可信）→ 跟随重定向（对齐 Kotlin instanceFollowRedirects=true）
/// - 其余（GET 元数据拉取）→ 拒绝（重定向是 SSRF 绕过路径）
/// @unchecked Sendable：无状态 delegate（不持有可变数据），见 review 三、Sendable 审计。
final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(task.originalRequest?.httpMethod == "POST" ? newRequest : nil)
    }
}
