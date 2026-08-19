import Darwin
import Foundation

/// SSRF 守卫（对齐 Kotlin `SsrfGuard`，并修正其 DNS rebinding / TOCTOU 缺口）：
/// - scheme ∈ {http, https}（Kotlin 的 ipfs 白名单在 java 下解析失败按畸形拒绝；Swift 直接拒绝非 http(s)）；
/// - host 非空；**DNS 解析失败 → fail-closed 拒绝**；
/// - 解析**全部**地址，任一私网/回环/链路本地即拒（含 IPv4-mapped IPv6、0.0.0.0/255.255.255.255、
///   100.64.0.0/10 CGNAT、fc00::/7 ULA）；
/// - 公网 IP 放行（对齐 Kotlin 测试：8.8.8.8 通过）；
/// - `enabled` 旁路开关仅 `internal` + `#if DEBUG`（勿做 public 可变全局）。
///
/// ⚠️ 残余 TOCTOU：check 与建连之间的二次 DNS 解析仍可能被 DNS rebinding 绕过（Kotlin 缺陷）。
/// 用 URLSession 时无对端 IP API，只能接受该残余风险（默认取舍）；威胁模型要求闭合时
/// 需改用 Network.framework `NWConnection` 连已校验 IP + TLS server-name（见 Nft-Swift 02 §4/§8）。
enum SsrfGuard {
    #if DEBUG
        nonisolated(unsafe) static var enabled = true
    #endif

    static func check(_ url: URL) -> Bool {
        #if DEBUG
            if !self.enabled {
                return true
            }
        #endif
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        // 解析全部地址：解析失败 = 拒绝（fail-closed）；任一地址私网/回环/链路本地 = 拒绝。
        guard let addresses = Self.addresses(of: host), !addresses.isEmpty else { return false }
        for ip in addresses where Self.isBlocked(ip) {
            return false
        }
        return true
    }

    // MARK: - DNS 解析（getaddrinfo 全量）

    private static func addresses(of host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &result)
        guard rc == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            if let ip = Self.numericHost(from: current.pointee.ai_addr) {
                addresses.append(ip)
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }

    private static func numericHost(from address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        return rc == 0 ? String(cString: host) : nil
    }

    // MARK: - 地址分类

    private static func isBlocked(_ ip: String) -> Bool {
        if ip.contains(":") {
            return self.isBlockedIPv6(ip)
        }
        return self.isBlockedIPv4(ip)
    }

    private static func isBlockedIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true } // 畸形 IPv4：fail-closed
        let (a, b, c, _) = (parts[0], parts[1], parts[2], parts[3])
        if a == 0 {
            return true
        } // 0.0.0.0/8（含 unspecified）
        if a == 127 {
            return true
        } // 回环
        if a == 10 {
            return true
        } // 私网 10/8
        if a == 172, (16 ... 31).contains(b) {
            return true
        } // 私网 172.16/12
        if a == 192, b == 168 {
            return true
        } // 私网 192.168/16
        if a == 169, b == 254 {
            return true
        } // 链路本地 169.254/16
        if a == 100, (64 ... 127).contains(b) {
            return true
        } // CGNAT 100.64/10
        if a == 255, b == 255, c == 255 {
            return true
        } // 255.255.255.255
        return false
    }

    private static func isBlockedIPv6(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower == "::" || lower == "::1" {
            return true
        } // unspecified / 回环
        if lower.hasPrefix("::ffff:") { // IPv4-mapped → 映射回 IPv4 再判
            return self.isBlockedIPv4(String(lower.dropFirst("::ffff:".count)))
        }
        if lower.hasPrefix("::") { // IPv4-compatible（已废弃）
            let rest = String(lower.dropFirst(2))
            if rest.contains(".") {
                return self.isBlockedIPv4(rest)
            }
        }
        // 首个 hextet 判定前缀段
        if let firstHextet = lower.split(separator: ":").first, let value = Int(firstHextet, radix: 16) {
            if value >= 0xFE80, value <= 0xFEBF {
                return true
            } // link-local fe80::/10
            if value >= 0xFEC0, value <= 0xFEFF {
                return true
            } // site-local fec0::/10（已废弃）
            if value >= 0xFC00, value <= 0xFDFF {
                return true
            } // ULA fc00::/7
        }
        return false
    }
}
