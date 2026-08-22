import Foundation

/// 十六进制编解码（查找表版，替代逐字节 `String(format: "%02x")`——后者每次调用做格式串
/// 解析 + 分配，是 Keccak/checksum/token 生成等热路径的常见开销点；本实现一次编码两 nibble）。
///
/// 归口后各模块共享同一实现：SwiftDid（Keccak256 / ChecksumUtils）、SwiftDappConnect
/// （WebAppInterface.makeResponseToken）、SwiftNft（EthTokenUriResolver / NftUrlUtils）。
public enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    /// bytes → 小写 hex 字符串（如 `[0xAB]` → `"ab"`）。
    public static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(self.digits[Int(byte >> 4)])
            out.append(self.digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// hex → bytes；非偶数长度或含非法字符 → nil（严格失败，不静默截断）。
    public static func decode(_ hex: some StringProtocol) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else { return nil }
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
