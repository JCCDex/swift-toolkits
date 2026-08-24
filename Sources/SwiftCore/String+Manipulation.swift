import Foundation

// MARK: - 通用字符串处理（归口 SwiftNft 原私有扩展，见 review SwiftNft 补充细节 / 用户要求）

public extension StringProtocol {
    /// 重复剥除前导 `prefix` 字符（`"///ipfs"` → `"ipfs"`）。
    func trimmingPrefix(_ prefix: Character) -> String {
        String(drop(while: { $0 == prefix }))
    }

    /// 剥除一次前导 `prefix` 子串（不匹配则原样返回）。
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : String(self)
    }
}

public extension String {
    /// hex 字符串 → UTF-8 文本（剥 `0x` 前缀、去空白；非偶数/非法字节 → ""，对齐 Kotlin 行为）。
    func hex2utf8() -> String {
        var clean = self
        if clean.lowercased().hasPrefix("0x") {
            clean = String(clean.dropFirst(2))
        }
        clean = clean.removingWhitespace()
        guard let bytes = Hex.decode(clean) else { return "" }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// 移除全部空白字符（正则 `\s+`；统一此前 `"\\s"` / `"\\s+"` 两种写法，见 review 六 C-4）。
    /// 结果等价（`\s` 逐个移除 vs `\s+` 连续段一次移除），`\s+` 少一次中间分配。
    func removingWhitespace() -> String {
        replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}
