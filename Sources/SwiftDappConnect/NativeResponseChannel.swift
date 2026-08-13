import Foundation

/// Native → JS 响应 payload 构造（Kotlin `NativeResponseChannel` 的序列化规则）。
public enum NativeResponseChannel {
    public static func successPayload(nonce: String, result: RPCResult?) -> [String: Any] {
        var payload: [String: Any] = ["nonce": nonce]
        payload["result"] = result?.jsonValue ?? NSNull()
        return payload
    }

    public static func errorPayload(nonce: String, code: Int, message: String) -> [String: Any] {
        [
            "nonce": nonce,
            "error": ["code": code, "message": message]
        ]
    }
}

extension [String: Any] {
    /// JSON 序列化辅助（仅用于需要与 Kotlin wire 格式严格对齐或日志时）。
    var jsonString: String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: self),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
