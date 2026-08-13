import Foundation

extension AsyncSequence {
    /// AsyncSequence 没有无参 `first()`（只有 `first(where:)`），
    /// 这里补一个取首个元素的便捷方法（等同迭代器 next()）。
    func firstValue() async rethrows -> Element? {
        var iterator = makeAsyncIterator()
        return try await iterator.next()
    }
}
