import CryptoKit
import Foundation

public actor VaultRepository {
    public static let shared = VaultRepository()

    private static let proofDomainSeparator = Data("CCDAO_VAULT_V1_PASSWORD_PROOF".utf8)
    private static let vaultAAD = Data("vault:v1".utf8)

    private let store: any VaultStoreDriver
    private let cipher: any VaultCipher
    private let keyDeriver: any VaultKeyDeriver
    private var sessionKey: Data?

    public static func get() -> VaultRepository {
        self.shared
    }

    public init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        cipher: (any VaultCipher)? = nil,
        keyDeriver: (any VaultKeyDeriver)? = nil
    ) {
        self.store = ProtobufVaultStoreDriver(
            storageURL: storageURL ?? Self.defaultStorageURL(),
            fileManager: fileManager
        )
        self.cipher = cipher ?? Self.defaultCipher()
        self.keyDeriver = keyDeriver ?? Argon2idVaultKeyDeriver()
    }

    public var isUnlocked: Bool {
        self.sessionKey != nil
    }

    public func lock() {
        self.sessionKey = nil
    }

    public func hasPassword() throws -> Bool {
        try self.loadStore().password != nil
    }

    @discardableResult
    public func initializePassword(
        _ password: Data,
        parameters: PasswordKDFParameters = PasswordKDFParameters()
    ) throws -> Bool {
        var store = try loadStore()
        guard store.password == nil else {
            return false
        }

        let salt = self.randomData(count: 16)
        let key = try keyDeriver.deriveKey(password: password, salt: salt, parameters: parameters)
        store.password = PasswordEnvelope(
            salt: salt,
            iterations: parameters.iterations,
            memoryKiB: parameters.memoryKiB,
            parallelism: parameters.parallelism,
            keyByteCount: parameters.keyByteCount,
            aad: Self.vaultAAD,
            proof: Self.computeProof(for: key)
        )
        try self.saveStore(store)
        self.sessionKey = key
        return true
    }

    public func verifyPassword(_ password: Data) throws -> Bool {
        let store = try loadStore()
        guard let passwordEnvelope = store.password else {
            return false
        }

        let key = try keyDeriver.deriveKey(
            password: password,
            salt: passwordEnvelope.salt,
            parameters: PasswordKDFParameters(
                iterations: passwordEnvelope.iterations,
                memoryKiB: passwordEnvelope.memoryKiB,
                parallelism: passwordEnvelope.parallelism,
                keyByteCount: passwordEnvelope.keyByteCount
            )
        )
        return Self.constantTimeEquals(Self.computeProof(for: key), passwordEnvelope.proof)
    }

    public func unlock(_ password: Data) throws -> Bool {
        let store = try loadStore()
        guard let passwordEnvelope = store.password else {
            return false
        }

        let key = try keyDeriver.deriveKey(
            password: password,
            salt: passwordEnvelope.salt,
            parameters: PasswordKDFParameters(
                iterations: passwordEnvelope.iterations,
                memoryKiB: passwordEnvelope.memoryKiB,
                parallelism: passwordEnvelope.parallelism,
                keyByteCount: passwordEnvelope.keyByteCount
            )
        )
        guard Self.constantTimeEquals(Self.computeProof(for: key), passwordEnvelope.proof) else {
            return false
        }
        self.sessionKey = key
        return true
    }

    public func importPrivateKey(address: String, privateKey: Data) throws {
        guard try !self.addressInKeys(address) else {
            return
        }

        var store = try loadStore()
        try store.keys.append(
            VaultEncryptedRecord(
                address: address,
                payload: self.cipher.encrypt(privateKey, key: self.requireSessionKey(), aad: self.addressAAD(address))
            )
        )
        try self.saveStore(store)
    }

    public func importMnemonic(
        address: String,
        mnemonic: Data,
        privateKey: Data,
        pathPrefix: String = "m/44'/60'/0'/0/0",
        language: String = "english"
    ) throws {
        try self.importPrivateKey(address: address, privateKey: privateKey)

        guard try !self.addressInMnemonics(address) else {
            return
        }

        var store = try loadStore()
        try store.mnemonics.append(
            VaultMnemonicRecord(
                address: address,
                payload: self.cipher.encrypt(mnemonic, key: self.requireSessionKey(), aad: self.mnemonicAAD(address)),
                derivationPath: pathPrefix,
                language: language
            )
        )
        try self.saveStore(store)
    }

    public func importSecret(address: String, privateKey: Data, secret: Data) throws {
        try self.importPrivateKey(address: address, privateKey: privateKey)

        guard try !self.addressInSecrets(address) else {
            return
        }

        var store = try loadStore()
        try store.secrets.append(
            VaultEncryptedRecord(
                address: address,
                payload: self.cipher.encrypt(secret, key: self.requireSessionKey(), aad: self.secretAAD(address))
            )
        )
        try self.saveStore(store)
    }

    public func importPrivateKeys(_ privateKeys: [VaultPrivateKeyImport]) throws {
        guard !privateKeys.isEmpty else {
            return
        }

        var store = try loadStore()
        for item in privateKeys {
            guard !self.containsAddress(item.address, in: store.keys) else {
                continue
            }

            try store.keys.append(
                VaultEncryptedRecord(
                    address: item.address,
                    payload: self.cipher.encrypt(item.privateKey, key: self.requireSessionKey(), aad: self.addressAAD(item.address))
                )
            )
        }
        try self.saveStore(store)
    }

    public func listAccounts() throws -> [String] {
        try self.loadStore().keys.map(\.address)
    }

    public func addressInKeys(_ address: String) throws -> Bool {
        try self.containsAddress(address, in: self.loadStore().keys)
    }

    public func addressInMnemonics(_ address: String) throws -> Bool {
        try self.containsAddress(address, in: self.loadStore().mnemonics)
    }

    public func addressInSecrets(_ address: String) throws -> Bool {
        try self.containsAddress(address, in: self.loadStore().secrets)
    }

    public func hasBiometric() throws -> Bool {
        try self.loadStore().biometric != nil
    }

    public func clearBiometric() throws {
        var store = try loadStore()
        store.biometric = nil
        try self.saveStore(store)
    }

    public func getBiometric() throws -> VaultSealedPayload {
        guard let biometric = try loadStore().biometric else {
            throw VaultError.biometricNotFound
        }
        return biometric
    }

    public func updateBiometric(ciphertext: Data, iv: Data) throws {
        var store = try loadStore()
        store.biometric = VaultSealedPayload(iv: iv, ciphertext: ciphertext)
        try self.saveStore(store)
    }

    public func getPrivateKey(address: String, password: Data) throws -> Data {
        try self.ensureUnlocked(with: password)
        return try self.getPrivateKeyInternal(address: address)
    }

    public func getMnemonic(address: String, password: Data) throws -> Data {
        try self.ensureUnlocked(with: password)
        return try self.getMnemonicInternal(address: address)
    }

    public func getSecret(address: String, password: Data) throws -> Data {
        try self.ensureUnlocked(with: password)
        return try self.getSecretInternal(address: address)
    }

    public func getMnemonicLanguage(address: String) throws -> String {
        let store = try loadStore()
        guard let entry = store.mnemonics.first(where: { $0.matches(address: address) }) else {
            throw VaultError.mnemonicNotFound
        }
        return entry.language
    }

    public func removeAddress(address: String, password: Data) throws {
        try self.ensureUnlocked(with: password)
        var store = try loadStore()
        store.keys.removeAll(where: { $0.matches(address: address) })
        store.mnemonics.removeAll(where: { $0.matches(address: address) })
        store.secrets.removeAll(where: { $0.matches(address: address) })
        try self.saveStore(store)
    }

    public func changePassword(
        oldPassword: Data,
        newPassword: Data,
        parameters: PasswordKDFParameters = PasswordKDFParameters()
    ) throws {
        try self.ensureUnlocked(with: oldPassword)

        let store = try loadStore()
        let currentKey = try requireSessionKey()
        let newSalt = self.randomData(count: 16)
        let newKey = try keyDeriver.deriveKey(password: newPassword, salt: newSalt, parameters: parameters)

        var newStore = VaultStoreSnapshot(
            password: PasswordEnvelope(
                salt: newSalt,
                iterations: parameters.iterations,
                memoryKiB: parameters.memoryKiB,
                parallelism: parameters.parallelism,
                keyByteCount: parameters.keyByteCount,
                aad: Self.vaultAAD,
                proof: Self.computeProof(for: newKey)
            ),
            keys: [],
            mnemonics: [],
            secrets: []
        )

        for entry in store.keys {
            let plaintext = try cipher.decrypt(entry.payload, key: currentKey, aad: self.addressAAD(entry.address))
            try newStore.keys.append(
                VaultEncryptedRecord(
                    address: entry.address,
                    payload: self.cipher.encrypt(plaintext, key: newKey, aad: self.addressAAD(entry.address))
                )
            )
        }

        for entry in store.mnemonics {
            let plaintext = try cipher.decrypt(entry.payload, key: currentKey, aad: self.mnemonicAAD(entry.address))
            try newStore.mnemonics.append(
                VaultMnemonicRecord(
                    address: entry.address,
                    payload: self.cipher.encrypt(plaintext, key: newKey, aad: self.mnemonicAAD(entry.address)),
                    derivationPath: entry.derivationPath,
                    language: entry.language
                )
            )
        }

        for entry in store.secrets {
            let plaintext = try cipher.decrypt(entry.payload, key: currentKey, aad: self.secretAAD(entry.address))
            try newStore.secrets.append(
                VaultEncryptedRecord(
                    address: entry.address,
                    payload: self.cipher.encrypt(plaintext, key: newKey, aad: self.secretAAD(entry.address))
                )
            )
        }

        try self.saveStore(newStore)
        self.sessionKey = newKey
    }

    public func clearAllData(password: Data? = nil) throws {
        if let password, try !verifyPassword(password) {
            throw VaultError.wrongPassword
        }
        self.lock()
        try self.saveStore(VaultStoreSnapshot())
    }

    public func getPrivateKeyInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.keys.first(where: { $0.matches(address: address) }) else {
            throw VaultError.privateKeyNotFound
        }
        return try self.cipher.decrypt(entry.payload, key: self.requireSessionKey(), aad: self.addressAAD(address))
    }

    public func getMnemonicInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.mnemonics.first(where: { $0.matches(address: address) }) else {
            throw VaultError.mnemonicNotFound
        }
        return try self.cipher.decrypt(entry.payload, key: self.requireSessionKey(), aad: self.mnemonicAAD(address))
    }

    public func getSecretInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.secrets.first(where: { $0.matches(address: address) }) else {
            throw VaultError.secretNotFound
        }
        return try self.cipher.decrypt(entry.payload, key: self.requireSessionKey(), aad: self.secretAAD(address))
    }

    static func defaultStorageURL() -> URL {
        let baseURL =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("SwiftVault", isDirectory: true)
            .appendingPathComponent("vault.pb", isDirectory: false)
    }

    private static func defaultCipher() -> any VaultCipher {
        #if canImport(Tink)
            #if targetEnvironment(simulator)
                return TinkVaultCipher(persistKeysetInKeychain: false)
            #else
                return TinkVaultCipher()
            #endif
        #else
            return CryptoKitVaultCipher()
        #endif
    }

    private func loadStore() throws -> VaultStoreSnapshot {
        try self.store.load()
    }

    private func saveStore(_ snapshot: VaultStoreSnapshot) throws {
        try self.store.save(snapshot)
    }

    private func requireSessionKey() throws -> Data {
        guard let sessionKey else {
            throw VaultError.vaultLocked
        }
        return sessionKey
    }

    private func ensureUnlocked(with password: Data) throws {
        if self.isUnlocked {
            guard try self.verifyPassword(password) else {
                throw VaultError.wrongPassword
            }
            return
        }

        guard try self.unlock(password) else {
            throw VaultError.wrongPassword
        }
    }

    private func containsAddress(_ address: String, in entries: [some AddressableRecord]) -> Bool {
        entries.contains(where: { $0.matches(address: address) })
    }

    private func addressAAD(_ address: String) -> Data {
        Data("address:\(self.normalizedAddress(address))".utf8)
    }

    private func mnemonicAAD(_ address: String) -> Data {
        Data("mnemonic:\(self.normalizedAddress(address))".utf8)
    }

    private func secretAAD(_ address: String) -> Data {
        Data("secret:\(self.normalizedAddress(address))".utf8)
    }

    private func normalizedAddress(_ address: String) -> String {
        address.lowercased()
    }

    private func randomData(count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func computeProof(for key: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: self.proofDomainSeparator, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var accumulator: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            accumulator |= left ^ right
        }
        return accumulator == 0
    }
}
