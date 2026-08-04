import Foundation
import SwiftProtobuf

final class ProtobufVaultStoreDriver: VaultStoreDriver {
    private let storageURL: URL
    private let fileManager: FileManager

    init(storageURL: URL, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
    }

    func load() throws -> VaultStoreSnapshot {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return VaultStoreSnapshot()
        }

        let data = try Data(contentsOf: storageURL)
        let vault = try Vault(serializedBytes: data)
        return VaultStoreSnapshot(
            password: mapPassword(vault.password),
            keys: vault.keys.map {
                VaultEncryptedRecord(
                    address: $0.address,
                    payload: VaultSealedPayload(iv: $0.iv, ciphertext: $0.ciphertext)
                )
            },
            mnemonics: vault.mnemonics.map {
                VaultMnemonicRecord(
                    address: $0.address,
                    payload: VaultSealedPayload(iv: $0.iv, ciphertext: $0.ciphertext),
                    derivationPath: $0.derivationPath,
                    language: $0.lang
                )
            },
            secrets: vault.secrets.map {
                VaultEncryptedRecord(
                    address: $0.address,
                    payload: VaultSealedPayload(iv: $0.iv, ciphertext: $0.ciphertext)
                )
            },
            biometric: vault.biometric.iv.isEmpty && vault.biometric.ciphertext.isEmpty
                ? nil
                : VaultSealedPayload(iv: vault.biometric.iv, ciphertext: vault.biometric.ciphertext)
        )
    }

    func save(_ snapshot: VaultStoreSnapshot) throws {
        var vault = Vault()
        if let password = snapshot.password {
            vault.password = mapPassword(password)
        }
        vault.keys = snapshot.keys.map {
            var entry = PrivateKeyEntry()
            entry.address = $0.address
            entry.iv = $0.payload.iv
            entry.ciphertext = $0.payload.ciphertext
            return entry
        }
        vault.mnemonics = snapshot.mnemonics.map {
            var entry = MnemonicEntry()
            entry.address = $0.address
            entry.iv = $0.payload.iv
            entry.ciphertext = $0.payload.ciphertext
            entry.derivationPath = $0.derivationPath
            entry.lang = $0.language
            return entry
        }
        vault.secrets = snapshot.secrets.map {
            var entry = SecretEntry()
            entry.address = $0.address
            entry.iv = $0.payload.iv
            entry.ciphertext = $0.payload.ciphertext
            return entry
        }
        if let biometric = snapshot.biometric {
            var entry = BiometricEntry()
            entry.iv = biometric.iv
            entry.ciphertext = biometric.ciphertext
            vault.biometric = entry
        }

        let directoryURL = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try vault.serializedData().write(to: storageURL, options: .atomic)
    }

    private func mapPassword(_ entry: PasswordEntry) -> PasswordEnvelope? {
        guard !entry.salt.isEmpty || !entry.proofCt.isEmpty else {
            return nil
        }

        return PasswordEnvelope(
            salt: entry.salt,
            iterations: Int(entry.iterations),
            memoryKiB: Int(entry.memoryKib),
            parallelism: Int(entry.parallelism),
            keyByteCount: Int(entry.keyByteCount == 0 ? 32 : entry.keyByteCount),
            aad: entry.aad,
            proof: entry.proofCt
        )
    }

    private func mapPassword(_ envelope: PasswordEnvelope) -> PasswordEntry {
        var entry = PasswordEntry()
        entry.salt = envelope.salt
        entry.iterations = Int32(envelope.iterations)
        entry.memoryKib = Int32(envelope.memoryKiB)
        entry.parallelism = Int32(envelope.parallelism)
        entry.aad = envelope.aad
        entry.proofCt = envelope.proof
        entry.keyByteCount = Int32(envelope.keyByteCount)
        return entry
    }

}
