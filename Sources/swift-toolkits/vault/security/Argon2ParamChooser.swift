import Foundation

public enum Argon2ParamChooser {
    public static func choose(
        preferLargeHeap: Bool = false,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> PasswordKDFParameters {
        let memoryMiB = Int(physicalMemoryBytes / 1024 / 1024)
        let targetMemoryMiB: Int
        if preferLargeHeap {
            targetMemoryMiB = min(max(memoryMiB / 8, 64), 256)
        } else {
            targetMemoryMiB = min(max(memoryMiB / 16, 32), 128)
        }

        return PasswordKDFParameters(
            iterations: 3,
            memoryKiB: targetMemoryMiB * 1024,
            parallelism: 1,
            keyByteCount: 32
        )
    }
}