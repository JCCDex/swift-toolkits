import Foundation

/// 异步 FIFO 互斥门：串行化 `async` 临界区，对应 Kotlin `Mutex`。
///
/// ⚠️ 不能用 `NSLock`（临界区跨 await、阻塞协作线程池、要求同线程 unlock）；
/// 不靠「actor 方法内直接写临界区」（actor 在 await 点可重入，并发调用会交错）；
/// 用**链式 Task**：每次调用排在上一次完成后执行，天然 FIFO 互斥。
public actor AsyncMutex {
    /// 队尾条目：`task` 是「完成信号」（前一个调用结束时解锁下一个等待者）；
    /// `id` 用于识别「本调用是否仍是队尾」（Task 是 struct，无法用 `===` 比较）。
    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var tail: Tail?

    public init() {}

    /// 串行执行 `body`：并发调用按到达顺序逐个完成（前一个结束才开始下一个）。
    /// `T: Sendable`——结果跨任务返回，须线程安全。
    ///
    /// 内存释放：`tail` 只保留到「下次入队或本调用结束」。本调用结束时若仍是队尾
    /// （期间无新调用），`defer` 主动断开——否则长生命周期下最后一段链式 Task 的
    /// 强引用会滞留到下一次调用才被替换（见用户 AsyncMutex 优化反馈）。
    public func withLock<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let previous = self.tail
        let id = UUID()
        let task = Task { () -> T in
            if let previous {
                _ = await previous.task.value
            }
            return await body()
        }
        // 队尾只存「完成信号」：task 完成后链式解锁下一个等待者。
        self.tail = Tail(id: id, task: Task { _ = await task.value })
        // 本调用返回前检查：若期间无新调用入队（仍是本调用的 id），断开释放。
        defer {
            if self.tail?.id == id {
                self.tail = nil
            }
        }
        return await task.value
    }
}
