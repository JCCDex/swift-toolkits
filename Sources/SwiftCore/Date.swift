import Foundation

/// ISO-8601 时间戳工具（原 `Json.nowISO`/`parseISO8601`，从 SwiftCore.Json 移出归口于此，
/// 见 review 跨模块重复 2.1；`Date.ISO8601FormatStyle`：Sendable、免每次新建格式化器）。
public extension Date {
    /// ISO-8601 时间戳（对齐 Kotlin `Instant.now().toString()`；固定毫秒精度，JS/后端可解析）。
    static func nowISO() -> String {
        self.nowString(from: Date())
    }

    /// 当前时间 + 偏移（VC expirationDate 用，对齐 Kotlin `Instant.now().plusMillis(...)`）。
    static func nowISO(offsetMillis: Int64) -> String {
        self.nowString(from: Date(timeIntervalSinceNow: TimeInterval(offsetMillis) / 1000.0))
    }

    /// 解析 ISO-8601（含不定长小数位，如 `...0.12Z` / `...0.100Z`；**同时兼容无小数位**）。
    /// 返回 nil 表示解析失败——调用方按「无法比较」处理（不得做字符串比较，见 Did-Swift 01 §6）。
    static func parseISO8601(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string)
    }

    /// 固定毫秒精度格式化（`2025-01-01T00:00:00.123Z`；ISO8601FormatStyle 默认 UTC 输出 `Z`）。
    private static func nowString(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
