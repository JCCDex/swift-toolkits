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
        guard self.fileManager.fileExists(atPath: self.storageURL.path) else {
            return VaultStoreSnapshot()
        }

        let data = try Data(contentsOf: storageURL)
        let vault = try Vault(serializedBytes: data)
        return VaultStoreSnapshot(
            password: self.mapPassword(vault.password),
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
            vault.password = self.mapPassword(password)
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

        let directoryURL = self.storageURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try vault.serializedData().write(to: self.storageURL, options: .atomic)
    }

    private func mapPassword(_ entry: PasswordEntry) -> PasswordEnvelope? {
        guard !entry.salt.isEmpty || !entry.proofCt.isEmpty else {
            return nil
        }

        return PasswordEnvelope(
            salt: entry.salt,
            iterations: Self.clamped(Int(entry.iterations), min: 1, max: 10000),
            memoryKiB: Self.clamped(Int(entry.memoryKib), min: 1, max: 1_048_576), // ≤1 GiB（原信任文件值可令 unlock 分配数百 MiB × 多次，见 review SwiftVault 补充细节）
            parallelism: Self.clamped(Int(entry.parallelism), min: 1, max: 64),
            keyByteCount: Int(entry.keyByteCount == 0 ? 32 : entry.keyByteCount),
            aad: entry.aad,
            proof: entry.proofCt
        )
    }

    /// 篡改 store 文件的 KDF 参数 DoS 防御：非法/超界值 clamp 到安全区间
    /// （文件被篡改后 unlock 不再无界分配内存；合法参数不受影响）。
    private static func clamped(_ value: Int, min lower: Int, max upper: Int) -> Int {
        min(max(value, lower), upper)
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
