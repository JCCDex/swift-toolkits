import Foundation
import SwiftCore

/// DID 文档 JSON 辅助（原 `SwiftDid/Util/DidJson`，并入 SwiftCore 后按职责拆分、
/// 再移回本模块）：文档字段读取归口本枚举，通用 JSON 取值/解析归口 `SwiftCore.Json`，
/// 时间戳归口 `SwiftCore.Date`。
enum DidJson {
    /// 读 Profile service 端点字段（对齐 Kotlin `readProfileField`：service/services 别名、type == "Profile"）。
    static func readProfileField(_ doc: String, _ key: String) -> String? {
        guard let root = Json.parseObject(doc) else { return nil }
        return self.readProfileField(root, key)
    }

    /// 字典版：调用方已 parse 时避免重复 JSON 解析（见 review 优化 #9/#10）。
    static func readProfileField(_ root: [String: Any], _ key: String) -> String? {
        let services = Json.readArray(root, "service") ?? Json.readArray(root, "services")
        guard let services else { return nil }
        for element in services {
            guard let service = element as? [String: Any],
                  Json.readString(service, "type") == "Profile",
                  let endpoint = Json.readDict(service, "serviceEndpoint")
            else { continue }
            let value = Json.readString(endpoint, key, default: "")
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// 取文档 `updated` 字段（raw 字符串；缺失/空白 → nil）。
    static func extractUpdated(_ doc: String) -> String? {
        guard let root = Json.parseObject(doc) else { return nil }
        let value = Json.readString(root, "updated", default: "")
        return value.isEmpty ? nil : value
    }
}
