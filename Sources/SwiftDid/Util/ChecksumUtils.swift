import Foundation

/// EIP-55 checksum（对齐 Kotlin `ChecksumUtils.toChecksumAddress`；keccak-256 来自自实现 `Keccak256`）。
///
/// 注意：与 Kotlin 一致——**长度/字符非法直接抛错**（非「原样返回」）；40 位合法 hex 一律重新
/// checksum（对已校验地址幂等）。调用方（generateVcId / buildAvatarCredentialId 等）用 `try?` 兜底。
public enum ChecksumUtils {
    public static func toChecksumAddress(_ rawAddress: String) throws -> String {
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

        var result = "0x"
        for (index, character) in lower.enumerated() {
            if character >= "a", character <= "f" {
                let nibble = hashHex[hashHex.index(hashHex.startIndex, offsetBy: index)]
                result.append(nibble >= Character("8") ? Character(character.uppercased()) : character)
            } else {
                result.append(character)
            }
        }
        return result
    }

    public enum ChecksumError: Error, Equatable {
        case invalidLength(Int)
        case invalidCharacters
    }
}
