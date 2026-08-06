import Foundation

public enum Argon2ParamChooser {
    public static func choose(
        preferLargeHeap: Bool = false,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> PasswordKDFParameters {
        let memoryMiB = Int(physicalMemoryBytes / 1024 / 1024)
        let targetMemoryMiB: Int = if preferLargeHeap {
            min(max(memoryMiB / 8, 64), 256)
        } else {
            min(max(memoryMiB / 16, 32), 128)
        }

        return PasswordKDFParameters(
            iterations: 3,
            memoryKiB: targetMemoryMiB * 1024,
            parallelism: 1,
            keyByteCount: 32
        )
    }
}
