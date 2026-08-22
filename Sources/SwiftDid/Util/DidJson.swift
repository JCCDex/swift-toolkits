import Foundation
import SwiftCore

/// org.json 风格 JSON 辅助（Swift 侧 [String: Any] / [Any] 容器）。
enum DidJson {
    static func parseObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    static func parseArray(_ string: String) -> [Any]? {
        guard let data = string.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }
        return array
    }

    static func stringify(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 对齐 org.json `JSONObject.optString(key, default)`：缺失/非标量 → 默认值
    /// （实现归口 `SwiftCore.Json.optString`，见跨模块重复 2.1）。
    static func optString(_ dict: [String: Any], _ key: String, default defaultValue: String = "") -> String {
        Json.optString(dict, key, default: defaultValue)
    }

    static func optDict(_ dict: [String: Any], _ key: String) -> [String: Any]? {
        dict[key] as? [String: Any]
    }

    static func optArray(_ dict: [String: Any], _ key: String) -> [Any]? {
        dict[key] as? [Any]
    }

    /// 缺失文档哨兵：`"{}"`（旧 IPFS tombstone）、`"null"`（JS null 序列化）、空串（trimmed）都判缺失
    /// （对齐 Kotlin `DidResolveUtils.isMissingDidDocument` + 空串防御，见 Did-Swift 03 §2）。
    static func isMissingDidDocument(_ doc: String) -> Bool {
        let trimmed = doc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "{}" || trimmed == "null"
    }

    /// 读 Profile service 端点字段（对齐 Kotlin `readProfileField`：service/services 别名、type == "Profile"）。
    static func readProfileField(_ doc: String, _ key: String) -> String? {
        guard let root = parseObject(doc) else { return nil }
        return self.readProfileField(root, key)
    }

    /// 字典版：调用方已 parse 时避免重复 JSON 解析（见 review 优化 #9/#10）。
    static func readProfileField(_ root: [String: Any], _ key: String) -> String? {
        let services = self.optArray(root, "service") ?? self.optArray(root, "services")
        guard let services else { return nil }
        for element in services {
            guard let service = element as? [String: Any],
                  optString(service, "type") == "Profile",
                  let endpoint = optDict(service, "serviceEndpoint")
            else { continue }
            let value = self.optString(endpoint, key)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// 取文档 `updated` 字段（raw 字符串；缺失/空白 → nil）。
    static func extractUpdated(_ doc: String) -> String? {
        guard let root = parseObject(doc) else { return nil }
        let value = self.optString(root, "updated")
        return value.isEmpty ? nil : value
    }

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
    /// `Date.ISO8601FormatStyle`：Sendable、免每次新建格式化器（见 review 性能专项 A-3）。
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
