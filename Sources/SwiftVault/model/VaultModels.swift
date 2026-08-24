import Foundation
import SwiftCore

public struct PasswordKDFParameters: Sendable, Codable, Equatable {
    public var iterations: Int
    public var memoryKiB: Int
    public var parallelism: Int
    public var keyByteCount: Int

    public init(
        iterations: Int = 3,
        memoryKiB: Int = 64 * 1024,
        parallelism: Int = 1,
        keyByteCount: Int = 32
    ) {
        self.iterations = iterations
        self.memoryKiB = memoryKiB
        self.parallelism = parallelism
        self.keyByteCount = keyByteCount
    }
}

public struct VaultPrivateKeyImport: Sendable, Hashable {
    public let address: String
    public let privateKey: Data

    public init(address: String, privateKey: Data) {
        self.address = address
        self.privateKey = privateKey
    }
}

public enum VaultError: Error, Equatable, Sendable {
    case vaultLocked
    case passwordNotInitialized
    case wrongPassword
    case privateKeyNotFound
    case mnemonicNotFound
    case secretNotFound
    case biometricNotFound
    case tinkUnavailable
    case cryptoRandomFailed(OSStatus)
}

struct VaultStoreSnapshot: Codable {
    var password: PasswordEnvelope?
    var keys: [VaultEncryptedRecord]
    var mnemonics: [VaultMnemonicRecord]
    var secrets: [VaultEncryptedRecord]
    var biometric: VaultSealedPayload?

    init(
        password: PasswordEnvelope? = nil,
        keys: [VaultEncryptedRecord] = [],
        mnemonics: [VaultMnemonicRecord] = [],
        secrets: [VaultEncryptedRecord] = [],
        biometric: VaultSealedPayload? = nil
    ) {
        self.password = password
        self.keys = keys
        self.mnemonics = mnemonics
        self.secrets = secrets
        self.biometric = biometric
    }
}

struct PasswordEnvelope: Codable {
    let salt: Data
    let iterations: Int
    let memoryKiB: Int
    let parallelism: Int
    let keyByteCount: Int
    let aad: Data
    let proof: Data
}

public struct VaultSealedPayload: Codable, Equatable, Sendable {
    public let iv: Data
    public let ciphertext: Data

    public init(iv: Data, ciphertext: Data) {
        self.iv = iv
        self.ciphertext = ciphertext
    }
}

protocol AddressableRecord {
    var address: String { get }
}

extension AddressableRecord {
    func matches(address: String) -> Bool {
        self.address.addressEquals(address)
    }
}

struct VaultEncryptedRecord: Codable, AddressableRecord {
    let address: String
    let payload: VaultSealedPayload
}

struct VaultMnemonicRecord: Codable, AddressableRecord {
    let address: String
    let payload: VaultSealedPayload
    let derivationPath: String
    let language: String
}
