import Foundation

/// 异步 FIFO 互斥门：串行化 `async` 临界区，对应 Kotlin `Mutex`。
///
/// ⚠️ 不能用 `NSLock`（临界区跨 await、阻塞协作线程池、要求同线程 unlock）；
/// 不靠「actor 方法内直接写临界区」（actor 在 await 点可重入，并发调用会交错）；
/// 用**链式 Task**：每次调用排在上一次完成后执行，天然 FIFO 互斥。
public actor AsyncMutex {
    private var tail: Task<Void, Never>?

    public init() {}

    /// 串行执行 `body`：并发调用按到达顺序逐个完成（前一个结束才开始下一个）。
    /// `T: Sendable`——结果跨任务返回，须线程安全。
    public func withLock<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let previous = self.tail
        let task = Task { () -> T in
            if let previous {
                _ = await previous.value
            }
            return await body()
        }
        self.tail = Task { _ = await task.value }
        return await task.value
    }
}
