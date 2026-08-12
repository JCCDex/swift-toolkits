import Foundation

/// 一次性续体容器：所有路径（结果/超时/取消）通过同一个盒子恢复，恢复后立即置 nil，
/// 保证「恰好一次 resume」。`@MainActor` 下读写天然串行；标注 `@unchecked Sendable`
/// 以允许在 `withTaskCancellationHandler` 的 `onCancel` 中访问。
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    var continuation: CheckedContinuation<T, Error>?

    func resume(with result: Result<T, Error>) {
        self.continuation?.resume(with: result)
        self.continuation = nil
    }

    func resume(throwing error: Error) {
        self.continuation?.resume(throwing: error)
        self.continuation = nil
    }
}

/// 就绪等待的一次性状态容器：续体 + 超时任务 + 监听移除器。
/// 字段平时只在 `@MainActor` 上读写；`onCancel` 通过 `cancel()` 访问，
/// 靠「先到先赢 + 幂等清理」保证安全。
final class ReadyWaitBox: @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Error>?
    var timeoutTask: Task<Void, Never>?
    var remover: (() -> Void)?

    func resumeIfPending() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func resumeIfPending(throwing error: Error) {
        self.continuation?.resume(throwing: error)
        self.continuation = nil
    }

    /// 调用方取消：取消超时任务、移除就绪监听、恢复续体（幂等，可重复调用）。
    func cancel() {
        self.timeoutTask?.cancel()
        self.remover?()
        self.resumeIfPending(throwing: CancellationError())
    }
}
