import CryptoKit
import Foundation

public final class CryptoKitVaultCipher: VaultCipher, Sendable {
    public init() {}

    public func encrypt(_ plaintext: Data, key: Data, aad: Data) throws -> VaultSealedPayload {
        let sealedBox = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        let nonce = Data(sealedBox.nonce)
        let ciphertext = sealedBox.ciphertext + sealedBox.tag
        return VaultSealedPayload(iv: nonce, ciphertext: ciphertext)
    }

    public func decrypt(_ payload: VaultSealedPayload, key: Data, aad: Data) throws -> Data {
        guard payload.ciphertext.count >= 16 else {
            throw CocoaError(.coderInvalidValue)
        }
        let ciphertext = payload.ciphertext.dropLast(16)
        let tag = payload.ciphertext.suffix(16)
        let nonce = try AES.GCM.Nonce(data: payload.iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: key), authenticating: aad)
    }
}
