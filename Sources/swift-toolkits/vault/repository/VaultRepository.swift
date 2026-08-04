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
        shared
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
        sessionKey != nil
    }

    public func lock() {
        sessionKey = nil
    }

    public func hasPassword() throws -> Bool {
        try loadStore().password != nil
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

        let salt = randomData(count: 16)
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
        try saveStore(store)
        sessionKey = key
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
        sessionKey = key
        return true
    }

    public func importPrivateKey(address: String, privateKey: Data) throws {
        guard try !addressInKeys(address) else {
            return
        }

        var store = try loadStore()
        store.keys.append(
            VaultEncryptedRecord(
                address: address,
                payload: try cipher.encrypt(privateKey, key: requireSessionKey(), aad: addressAAD(address))
            )
        )
        try saveStore(store)
    }

    public func importMnemonic(
        address: String,
        mnemonic: Data,
        privateKey: Data,
        pathPrefix: String = "m/44'/60'/0'/0/0",
        language: String = "english"
    ) throws {
        try importPrivateKey(address: address, privateKey: privateKey)

        guard try !addressInMnemonics(address) else {
            return
        }

        var store = try loadStore()
        store.mnemonics.append(
            VaultMnemonicRecord(
                address: address,
                payload: try cipher.encrypt(mnemonic, key: requireSessionKey(), aad: mnemonicAAD(address)),
                derivationPath: pathPrefix,
                language: language
            )
        )
        try saveStore(store)
    }

    public func importSecret(address: String, privateKey: Data, secret: Data) throws {
        try importPrivateKey(address: address, privateKey: privateKey)

        guard try !addressInSecrets(address) else {
            return
        }

        var store = try loadStore()
        store.secrets.append(
            VaultEncryptedRecord(
                address: address,
                payload: try cipher.encrypt(secret, key: requireSessionKey(), aad: secretAAD(address))
            )
        )
        try saveStore(store)
    }

    public func importPrivateKeys(_ privateKeys: [VaultPrivateKeyImport]) throws {
        guard !privateKeys.isEmpty else {
            return
        }

        var store = try loadStore()
        for item in privateKeys {
            guard !containsAddress(item.address, in: store.keys) else {
                continue
            }

            store.keys.append(
                VaultEncryptedRecord(
                    address: item.address,
                    payload: try cipher.encrypt(item.privateKey, key: requireSessionKey(), aad: addressAAD(item.address))
                )
            )
        }
        try saveStore(store)
    }

    public func listAccounts() throws -> [String] {
        try loadStore().keys.map(\.address)
    }

    public func addressInKeys(_ address: String) throws -> Bool {
        containsAddress(address, in: try loadStore().keys)
    }

    public func addressInMnemonics(_ address: String) throws -> Bool {
        containsAddress(address, in: try loadStore().mnemonics)
    }

    public func addressInSecrets(_ address: String) throws -> Bool {
        containsAddress(address, in: try loadStore().secrets)
    }

    public func hasBiometric() throws -> Bool {
        try loadStore().biometric != nil
    }

    public func clearBiometric() throws {
        var store = try loadStore()
        store.biometric = nil
        try saveStore(store)
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
        try saveStore(store)
    }

    public func getPrivateKey(address: String, password: Data) throws -> Data {
        try ensureUnlocked(with: password)
        return try getPrivateKeyInternal(address: address)
    }

    public func getMnemonic(address: String, password: Data) throws -> Data {
        try ensureUnlocked(with: password)
        return try getMnemonicInternal(address: address)
    }

    public func getSecret(address: String, password: Data) throws -> Data {
        try ensureUnlocked(with: password)
        return try getSecretInternal(address: address)
    }

    public func getMnemonicLanguage(address: String) throws -> String {
        let store = try loadStore()
        guard let entry = store.mnemonics.first(where: { $0.matches(address: address) }) else {
            throw VaultError.mnemonicNotFound
        }
        return entry.language
    }

    public func removeAddress(address: String, password: Data) throws {
        try ensureUnlocked(with: password)
        var store = try loadStore()
        store.keys.removeAll(where: { $0.matches(address: address) })
        store.mnemonics.removeAll(where: { $0.matches(address: address) })
        store.secrets.removeAll(where: { $0.matches(address: address) })
        try saveStore(store)
    }

    public func changePassword(
        oldPassword: Data,
        newPassword: Data,
        parameters: PasswordKDFParameters = PasswordKDFParameters()
    ) throws {
        try ensureUnlocked(with: oldPassword)

        let store = try loadStore()
        let currentKey = try requireSessionKey()
        let newSalt = randomData(count: 16)
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
            let plaintext = try cipher.decrypt(entry.payload, key: currentKey, aad: addressAAD(entry.address))
            newStore.keys.append(
                VaultEncryptedRecord(
                    address: entry.address,
                    payload: try cipher.encrypt(plaintext, key: newKey, aad: addressAAD(entry.address))
                )
            )
        }

        for entry in store.mnemonics {
            let plaintext = try cipher.decrypt(entry.payload, key: currentKey, aad: mnemonicAAD(entry.address))
            newStore.mnemonics.append(
                VaultMnemonicRecord(
                    address: entry.address,
                    payload: try cipher.encrypt(plaintext, key: newKey, aad: mnemonicAAD(entry.address)),
                    derivationPath: entry.derivationPath,
                    language: entry.language
                )
            )
        }

        for entry in store.secrets {
            let plaintext = try cipher.decrypt(entry.payload, key: currentKey, aad: secretAAD(entry.address))
            newStore.secrets.append(
                VaultEncryptedRecord(
                    address: entry.address,
                    payload: try cipher.encrypt(plaintext, key: newKey, aad: secretAAD(entry.address))
                )
            )
        }

        try saveStore(newStore)
        sessionKey = newKey
    }

    public func clearAllData(password: Data? = nil) throws {
        if let password, !(try verifyPassword(password)) {
            throw VaultError.wrongPassword
        }
        lock()
        try saveStore(VaultStoreSnapshot())
    }

    public func getPrivateKeyInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.keys.first(where: { $0.matches(address: address) }) else {
            throw VaultError.privateKeyNotFound
        }
        return try cipher.decrypt(entry.payload, key: requireSessionKey(), aad: addressAAD(address))
    }

    public func getMnemonicInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.mnemonics.first(where: { $0.matches(address: address) }) else {
            throw VaultError.mnemonicNotFound
        }
        return try cipher.decrypt(entry.payload, key: requireSessionKey(), aad: mnemonicAAD(address))
    }

    public func getSecretInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.secrets.first(where: { $0.matches(address: address) }) else {
            throw VaultError.secretNotFound
        }
        return try cipher.decrypt(entry.payload, key: requireSessionKey(), aad: secretAAD(address))
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
        try store.load()
    }

    private func saveStore(_ snapshot: VaultStoreSnapshot) throws {
        try store.save(snapshot)
    }

    private func requireSessionKey() throws -> Data {
        guard let sessionKey else {
            throw VaultError.vaultLocked
        }
        return sessionKey
    }

    private func ensureUnlocked(with password: Data) throws {
        if isUnlocked {
            guard try verifyPassword(password) else {
                throw VaultError.wrongPassword
            }
            return
        }

        guard try unlock(password) else {
            throw VaultError.wrongPassword
        }
    }

    private func containsAddress<T: AddressableRecord>(_ address: String, in entries: [T]) -> Bool {
        entries.contains(where: { $0.matches(address: address) })
    }

    private func addressAAD(_ address: String) -> Data {
        Data("address:\(normalizedAddress(address))".utf8)
    }

    private func mnemonicAAD(_ address: String) -> Data {
        Data("mnemonic:\(normalizedAddress(address))".utf8)
    }

    private func secretAAD(_ address: String) -> Data {
        Data("secret:\(normalizedAddress(address))".utf8)
    }

    private func normalizedAddress(_ address: String) -> String {
        address.lowercased()
    }

    private func randomData(count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func computeProof(for key: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: proofDomainSeparator, using: SymmetricKey(data: key))
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
