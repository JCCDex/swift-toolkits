import Foundation
import SwiftCore

/// keccak-256（**0x01 padding，非 SHA3-256 的 0x06**）——EIP-55 checksum 与 VCID 生成需要。
///
/// 自实现说明（见 Nft-Swift/Did-Swift 04 坑 #3）：CryptoKit / swift-crypto 不含 keccak-256；
/// 设计首选专门轻量依赖，自实现仅兜底——本实现以经典 ρ/π 常量表 + 标准测试向量做 KAT 全量交叉验证
/// （`Keccak256Tests`：空串 / "abc" / 0x61-0x80 序列 / 长消息 / EIP-55 地址向量）。
enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008
    ]

    /// ρ 轮转偏移（lane 索引 = x + 5y，经典常量表，已验证于标准测试向量）。
    private static let rotationOffsets: [Int] = [
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14
    ]

    /// π 置换（B[pi[i]] = ROTL(A[i], rho[i])）。
    private static let permutationIndexes: [Int] = [
        0, 10, 20, 5, 15, 16, 1, 11, 21, 6, 7, 17, 2, 12, 22, 23, 8, 18, 3, 13, 14, 24, 9, 19, 4
    ]

    static func hash(data: Data) -> Data {
        let rate = 136 // 1088 位速率（256 位输出）

        // Keccak padding：0x01 0x00... 0x80（多字节填充，rate 整数倍）
        var padded = data
        let remainder = data.count % rate
        let padBytes = rate - remainder
        padded.append(0x01)
        if padBytes > 1 {
            padded.append(Data(repeating: 0, count: padBytes - 1))
        }
        padded[padded.count - 1] |= 0x80

        var state = [UInt64](repeating: 0, count: 25)
        // permute 工作区一次分配、多块复用（原每次 permute 重新分配 c/d/b，见 review B-2）。
        var c = [UInt64](repeating: 0, count: 5)
        var d = [UInt64](repeating: 0, count: 5)
        var b = [UInt64](repeating: 0, count: 25)

        // Absorb：按 8 字节 lane 一次读入（每块 17 个 lane 异或进 state[0..<17]；
        // loadUnaligned 对 Data 无对齐假设，避免逐字节 div/mod + 移位组装）。
        var offset = 0
        while offset < padded.count {
            let end = min(offset + rate, padded.count)
            padded.withUnsafeBytes { raw in
                var laneIndex = 0
                for byteOffset in stride(from: offset, to: end, by: 8) {
                    state[laneIndex] ^= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt64.self))
                    laneIndex += 1
                }
            }
            offset = end
            Self.permute(&state, c: &c, d: &d, b: &b)
        }

        // Squeeze：取状态前 32 字节
        var out = Data()
        var index = 0
        while out.count < 32 {
            let lane = state[index / 8]
            for shift in 0 ..< 8 where out.count < 32 {
                out.append(UInt8((lane >> (8 * shift)) & 0xFF))
            }
            index += 8
            if index >= 25 * 8 {
                Self.permute(&state, c: &c, d: &d, b: &b)
                index = 0
            }
        }
        return out
    }

    static func hex(data: Data) -> String {
        Hex.encode([UInt8](data))
    }

    private static func permute(_ a: inout [UInt64], c: inout [UInt64], d: inout [UInt64], b: inout [UInt64]) {
        for round in 0 ..< 24 {
            // θ
            for x in 0 ..< 5 {
                c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20]
            }
            for x in 0 ..< 5 {
                d[x] = c[(x + 4) % 5] ^ self.rotl(c[(x + 1) % 5], 1)
            }
            for x in 0 ..< 5 {
                for y in 0 ..< 5 {
                    a[x + 5 * y] ^= d[x]
                }
            }
            // ρ + π
            for i in 0 ..< 25 {
                b[self.permutationIndexes[i]] = self.rotl(a[i], UInt64(self.rotationOffsets[i]))
            }
            // χ
            for y in 0 ..< 5 {
                for x in 0 ..< 5 {
                    let idx = x + 5 * y
                    a[idx] = b[idx] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                }
            }
            // ι
            a[0] ^= self.roundConstants[round]
        }
    }

    private static func rotl(_ value: UInt64, _ shift: UInt64) -> UInt64 {
        shift == 0 ? value : (value << shift) | (value >> (64 - shift))
    }
}
