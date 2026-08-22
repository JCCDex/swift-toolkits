import Foundation

/// org.json 风格 JSON 取值工具（Swift 侧 `[String: Any]` 容器）。
///
/// 归口 SwiftDid（`DidJson` / 门面 `readString`/`readLong`/`readValue`）与 SwiftNft
/// （`NftUrlUtils.optString` / 门面 `readString`/`readLong`/`readValue`）各自重复实现，
/// 统一于此（见 review 跨模块重复 2.1）。
public enum Json {
    /// 对齐 org.json `JSONObject.optString(key, default)`：缺失/非标量 → 默认值。
    /// 标量规则：String 原样；Bool → `"true"`/`"false"`；NSNumber → `stringValue`。
    public static func optString(_ dict: [String: Any], _ key: String, default defaultValue: String = "") -> String {
        guard let value = dict[key] else { return defaultValue }
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return defaultValue
    }

    /// 点分路径取值（如 `"credentialSubject.tokenId"`；剥离 `"$."` 前缀；
    /// 任一环节非字典 → nil；命中 NSNull → nil）。
    public static func readValue(_ root: [String: Any], _ path: String) -> Any? {
        let cleaned = path.replacingOccurrences(of: "$.", with: "")
        var current: Any = root
        for part in cleaned.split(separator: ".") {
            guard let dict = current as? [String: Any], let value = dict[String(part)] else { return nil }
            current = value
        }
        return current is NSNull ? nil : current
    }

    /// 点分路径标量转 String（String 原样 / Bool → `"true"`|`"false"` / NSNumber → `stringValue`）。
    public static func readString(_ root: [String: Any], _ path: String) -> String? {
        guard let value = self.readValue(root, path) else { return nil }
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    /// 带默认值版本：路径缺失/非标量 → 默认值（常用 `default: ""` 替代 `?? ""`）。
    public static func readString(_ root: [String: Any], _ path: String, default defaultValue: String) -> String {
        self.readString(root, path) ?? defaultValue
    }

    /// 点分路径标量转 Int64（NSNumber → `int64Value` / String → `Int64(string)`）。
    public static func readLong(_ root: [String: Any], _ path: String) -> Int64? {
        guard let value = self.readValue(root, path) else { return nil }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }

    /// 带默认值版本：路径缺失/非标量 → 默认值（常用 `default: 0` 替代 `?? 0`）。
    public static func readLong(_ root: [String: Any], _ path: String, default defaultValue: Int64) -> Int64 {
        self.readLong(root, path) ?? defaultValue
    }
}
