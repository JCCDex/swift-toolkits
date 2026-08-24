import Foundation

/// 一次性续体容器：所有路径（结果/超时/取消）通过同一个盒子恢复，恢复后立即置 nil，
/// 保证「恰好一次 resume」。
///
/// 线程模型（P0-2 修复）：`onCancel` 由 `withTaskCancellationHandler` 在**取消线程**同步执行，
/// 因此调用方（`WebViewBridgeClient.callJSMethod`）已约定把 onCancel 内的 resume 跳回主线程；
/// 这里再用 `NSLock` 把所有字段访问（install / resume / take）做成原子操作作为纵深防御——
/// 即使未来某条路径忘记跳主线程，两个线程并发 resume 也只会有一个拿到续体，绝不
/// double-resume。标注 `@unchecked Sendable`：允许盒子被 onCancel 闭包跨线程捕获，
/// 正确性由锁保证。
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    /// 安装续体（setup 阶段调用；与 resume 互斥，避免「赋值中被打断」）。
    func install(_ continuation: CheckedContinuation<T, Error>) {
        self.lock.lock()
        self.continuation = continuation
        self.lock.unlock()
    }

    /// 续体是否已安装（供等待 setup 完成使用）。
    var isInstalled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.continuation != nil
    }

    func resume(with result: Result<T, Error>) {
        self.take()?.resume(with: result)
    }

    func resume(throwing error: Error) {
        self.take()?.resume(throwing: error)
    }

    /// 原子取走续体：并发调用只有一个能拿到非 nil（先到先赢，后到者 no-op）。
    private func take() -> CheckedContinuation<T, Error>? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

/// 就绪等待的一次性状态容器：续体 + 超时任务 + 监听移除器。
/// 字段只在 `@MainActor` 上读写（`waitForReady` 的 setup、就绪监听、超时任务均为
/// @MainActor，`onCancel` 已约定跳回主线程再调 `cancel()`），靠「先到先赢 + 幂等清理」
/// 保证安全；`@unchecked Sendable` 仅用于允许 onCancel 闭包跨线程捕获盒子。
final class ReadyWaitBox: @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Error>?
    var timeoutTask: Task<Void, Never>?
    var remover: (() -> Void)?

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func resume(throwing error: Error) {
        self.continuation?.resume(throwing: error)
        self.continuation = nil
    }

    /// 调用方取消：取消超时任务、移除就绪监听、恢复续体（幂等，可重复调用）。
    /// ⚠️ 仅在 @MainActor 调用（`onCancel` 必须跳主线程，见 `PromiseGateway.waitForReady`）。
    func cancel() {
        self.timeoutTask?.cancel()
        self.remover?()
        self.resume(throwing: CancellationError())
    }
}
