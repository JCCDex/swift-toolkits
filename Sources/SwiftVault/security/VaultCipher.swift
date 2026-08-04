import Foundation

public protocol VaultCipher: Sendable {
    func encrypt(_ plaintext: Data, key: Data, aad: Data) throws -> VaultSealedPayload
    func decrypt(_ payload: VaultSealedPayload, key: Data, aad: Data) throws -> Data
}
