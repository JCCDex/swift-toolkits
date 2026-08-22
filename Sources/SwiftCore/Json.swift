import Foundation

/// org.json 风格 JSON 取值工具（Swift 侧 `[String: Any]` 容器）。
///
/// 归口 SwiftDid（原 `DidJson` / 门面 `readString`/`readLong`/`readValue`）与 SwiftNft
/// （原 `NftUrlUtils.optString` / 门面 `readString`/`readLong`/`readValue`）各自重复实现，
/// 统一于此（见 review 跨模块重复 2.1）。DID 文档字段读取归口 `DidJson`、时间戳归口
/// `Date`（原 `DidJson` 整体并入后拆分，2025-08-22）。
public enum Json {

    // MARK: - 取值

    /// 单键取值：对齐 org.json `JSONObject.optJSONObject(key)`，缺失/非字典 → nil。
    public static func readDict(_ dict: [String: Any], _ key: String) -> [String: Any]? {
        dict[key] as? [String: Any]
    }

    /// 单键取值：对齐 org.json `JSONObject.optJSONArray(key)`，缺失/非数组 → nil。
    public static func readArray(_ dict: [String: Any], _ key: String) -> [Any]? {
        dict[key] as? [Any]
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

    /// 点分路径标量转 String（String 原样 / Bool → `"true"`|`"false"` / NSNumber → `stringValue`；
    /// 单键场景（key 无 `.`）等价于 org.json `optString`）。
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

    // MARK: - 解析 / 序列化

    /// 解析 JSON 字符串为字典（非法/非字典 → nil）。
    public static func parseObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    /// 解析 JSON 字符串为数组（非法/非数组 → nil）。
    public static func parseArray(_ string: String) -> [Any]? {
        guard let data = string.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }
        return array
    }

    /// 序列化为 JSON 字符串（非法值 → ""）。
    public static func stringify(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 缺失 JSON 文档哨兵（对齐 Kotlin `DidResolveUtils.isMissingDidDocument` + 空串防御，
    /// 见 Did-Swift 03 §2）：`"{}"`（旧 IPFS tombstone）、`"null"`（JS null 序列化）、
    /// 空串（trimmed）都判缺失。
    public static func isEmpty(_ doc: String) -> Bool {
        let trimmed = doc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "{}" || trimmed == "null"
    }
}
