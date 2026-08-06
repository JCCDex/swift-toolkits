import Argon2Swift
import Foundation

public final class Argon2idVaultKeyDeriver: VaultKeyDeriver {
    public init() {}

    public func deriveKey(password: Data, salt: Data, parameters: PasswordKDFParameters) throws -> Data {
        let result = try Argon2Swift.hashPasswordBytes(
            password: password,
            salt: Salt(bytes: salt),
            iterations: parameters.iterations,
            memory: parameters.memoryKiB,
            parallelism: parameters.parallelism,
            length: parameters.keyByteCount,
            type: .id,
            version: .V13
        )
        return result.hashData()
    }
}
