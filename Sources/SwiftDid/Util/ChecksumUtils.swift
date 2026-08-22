import Foundation

/// EIP-55 checksum（对齐 Kotlin `ChecksumUtils.toChecksumAddress`；keccak-256 来自自实现 `Keccak256`）。
///
/// 注意：与 Kotlin 一致——**长度/字符非法直接抛错**（非「原样返回」）；40 位合法 hex 一律重新
/// checksum（对已校验地址幂等）。调用方（generateVcId / buildAvatarCredentialId 等）用 `try?` 兜底。
enum ChecksumUtils {
    static func toChecksumAddress(_ rawAddress: String) throws -> String {
        var clean = rawAddress
        if clean.hasPrefix("0x") || clean.hasPrefix("0X") {
            clean = String(clean.dropFirst(2))
        }
        guard clean.count == 40 else {
            throw ChecksumError.invalidLength(clean.count)
        }
        guard clean.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            throw ChecksumError.invalidCharacters
        }
        let lower = clean.lowercased()
        let hashHex = Keccak256.hex(data: Keccak256.hash(data: Data(lower.utf8)))
        // EIP-55：hash nibble ≥ 0x8 时对应小写字母大写化。UTF-8 字节迭代，
        // 避免逐字符 String.index(offsetBy:) 的 O(n²) 与每字符 uppercased() 分配。
        let hashBytes = Array(hashHex.utf8)
        var out = [UInt8]()
        out.reserveCapacity(42)
        out.append(contentsOf: "0x".utf8)
        var index = 0
        for ch in lower.utf8 {
            if ch >= 0x61, ch <= 0x66 { // 'a'...'f'
                out.append(hashBytes[index] >= 0x38 ? ch - 32 : ch) // '8' == 0x38
            } else {
                out.append(ch)
            }
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 出错（长度/字符非法）时返回传入的默认值（替代 `try? ... ?? fallback` 组合）。
    static func toChecksumAddress(_ rawAddress: String, or fallback: String) -> String {
        (try? self.toChecksumAddress(rawAddress)) ?? fallback
    }

    /// 可选地址版本：nil 直接返回默认值（替代 `map { toChecksumAddress($0, or: "") } ?? ""` 的双重默认）。
    static func toChecksumAddress(_ rawAddress: String?, or fallback: String) -> String {
        guard let rawAddress else { return fallback }
        return (try? self.toChecksumAddress(rawAddress)) ?? fallback
    }

    enum ChecksumError: Error, Equatable, Sendable {
        case invalidLength(Int)
        case invalidCharacters
    }
}
