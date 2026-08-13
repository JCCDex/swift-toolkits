import Foundation

/// 归一化页面 URL 为 web origin 键：`scheme://host[:port]`（M-R4 / H-R2）。
public enum WebOrigin {
    /// 原生钱包 UI 内部取密钥的哨兵 origin（M-18），宿主不得将其当作可授权 web origin。
    public static let walletInternal = "wallet_internal"

    /// 仅接受 http/https + 非空 host；host/scheme 小写；非默认端口保留。
    public static func normalize(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }

        let defaultPort = scheme == "https" ? 443 : 80
        if let port = components.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}
