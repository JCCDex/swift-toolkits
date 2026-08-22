import Foundation

public extension AsyncSequence {
    /// 取首个元素（Swift 6.2 标准库的 `AsyncSequence` 只有 `first(where:)`，无无参 `first()`）。
    ///
    /// 归口到 SwiftCore：SwiftDappConnect（`EthMiddleware`/`SwtcMiddleware` 的
    /// `accountProvider.accounts.firstValue()`）与 SwiftNft 各有一份重复实现，统一于此。
    /// 注意：仅消费首个元素即终止迭代（等同迭代器 `next()`）；对「每次访问返回新流」的
    /// provider 语义安全，对共享/多播流会排空首个订阅者——使用前需确认流语义。
    func firstValue() async rethrows -> Element? {
        var iterator = makeAsyncIterator()
        return try await iterator.next()
    }
}
