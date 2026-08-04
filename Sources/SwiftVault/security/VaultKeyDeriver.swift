import Foundation

public protocol VaultKeyDeriver {
    func deriveKey(password: Data, salt: Data, parameters: PasswordKDFParameters) throws -> Data
}
