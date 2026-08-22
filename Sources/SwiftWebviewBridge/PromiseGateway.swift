import Foundation

@MainActor
final class PromiseGateway {
    struct PendingCall {
        let onResult: (Result<String, Error>) -> Void
        let timeoutTask: Task<Void, Never>
    }

    private var pending: [String: PendingCall] = [:]
    private var readyListeners: [UUID: () -> Void] = [:]
    private(set) var isReady = false

    var pendingCount: Int {
        self.pending.count
    }

    // MARK: - JS -> Native

    func onPromiseResult(id: String, resultJson: String) {
        self.finish(id: id, result: Self.parseResult(resultJson))
    }

    func onBridgeReady() {
        self.isReady = true
        let listeners = self.readyListeners.values
        self.readyListeners.removeAll()
        for listener in listeners {
            listener()
        }
    }

    // MARK: - Native -> JS

    /// 注册一次调用：超时任务先到则回 timeout，JS 结果先到则取消超时任务。
    func register(
        id: String,
        timeoutMs: TimeInterval,
        onResult: @escaping (Result<String, Error>) -> Void
    ) {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs * 1_000_000))
            self?.finish(id: id, result: .failure(WebviewBridgeError.timeout))
        }
        self.pending[id] = PendingCall(onResult: onResult, timeoutTask: timeoutTask)
    }

    /// 移除 pending 并取消超时任务。调用方取消 / JS 迟到回调 / destroy 时使用。
    func remove(id: String) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeoutTask.cancel()
    }

    // MARK: - 就绪等待

    /// 等待 WebView 就绪，超时抛 `.timeout`。`ReadyWaitBox` 保证
    /// 就绪/超时/取消三条路径恰好一条恢复续体，且都正确清理。
    func waitForReady(timeoutMs: TimeInterval) async throws {
        if self.isReady {
            return
        }

        let box = ReadyWaitBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.continuation = continuation

                box.remover = self.addReadyListener { [weak box] in
                    box?.timeoutTask?.cancel()
                    box?.resumeIfPending()
                }

                box.timeoutTask = Task { @MainActor [weak box] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs * 1_000_000))
                    box?.remover?()
                    box?.resumeIfPending(throwing: WebviewBridgeError.timeout)
                }

                // 关闭「取消先于 setup」的竞态窗口：setup 后若任务已被取消，立即自清理。
                if Task.isCancelled {
                    box.cancel()
                }
            }
        } onCancel: {
            // P0-2：onCancel 在「取消线程」同步执行；box.cancel() 会经 remover 改写
            // gateway.readyListeners 并恢复续体——必须跳主线程，与就绪监听/超时任务
            // 串行，避免字典数据竞争与 double-resume（ReadyWaitBox 仅在 @MainActor 访问）。
            Task { @MainActor [weak box] in
                box?.cancel()
            }
        }
    }

    func addReadyListener(_ listener: @escaping () -> Void) -> () -> Void {
        if self.isReady {
            listener()
            return {}
        }
        let token = UUID()
        self.readyListeners[token] = listener
        return { [weak self] in
            self?.readyListeners.removeValue(forKey: token)
        }
    }

    func resetReady() {
        self.isReady = false
        self.readyListeners.removeAll()
    }

    func clearAll() {
        // P0-3：必须恢复 pending 调用者——否则其 withCheckedThrowingContinuation 永不
        // resume（destroy 中途调用时超时任务被取消、迟到 JS 结果也因 pending 已清而
        // no-op），调用者永久悬挂并强持有 client/box/闭包。与 finish 同款
        // 「先取走再回调」，重入安全；超时任务先取消（后到者全部 no-op）。
        let calls = Array(self.pending.values)
        self.pending.removeAll()
        for call in calls {
            call.timeoutTask.cancel()
            call.onResult(.failure(WebviewBridgeError.webViewUnavailable))
        }
        self.readyListeners.removeAll()
        self.isReady = false
    }

    // MARK: - 内部

    /// 完成一次调用。结果/超时先到先赢，后到者发现 pending 已移除则 no-op。
    private func finish(id: String, result: Result<String, Error>) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeoutTask.cancel()
        call.onResult(result)
    }

    /// 与 Kotlin 相同的解析规则：
    /// - {error} -> jsError
    /// - {result: String} -> 原样
    /// - {result: 数字/布尔/对象} -> JSON 文本（123 -> "123"）
    /// - 缺 result/error -> invalidResponseFormat；非法 JSON -> malformedJSON
    static func parseResult(_ resultJson: String) -> Result<String, Error> {
        guard
            let data = resultJson.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure(WebviewBridgeError.malformedJSON(resultJson))
        }

        if let error = object["error"] as? String {
            return .failure(WebviewBridgeError.jsError(error))
        }
        guard object["result"] != nil else {
            return .failure(WebviewBridgeError.invalidResponseFormat)
        }

        guard let result = object["result"] else {
            return .success("null")
        }
        if let string = result as? String {
            return .success(string)
        }
        // 顶层数字/布尔需要 .fragmentsAllowed；对象/NSNull 不受影响。
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return .success(text)
        }
        // 兜底：NSNumber 用 stringValue（固定格式，与 locale 无关——`String(describing:)` 会随
        // locale 变小数点/分组，见 review F-3）。
        if let number = result as? NSNumber {
            return .success(number.stringValue)
        }
        return .success(String(describing: result))
    }
}
