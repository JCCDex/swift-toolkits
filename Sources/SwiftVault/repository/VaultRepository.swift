import CryptoKit
import Foundation
import Security

public actor VaultRepository {
    public static let shared = VaultRepository()

    private static let proofDomainSeparator = Data("CCDAO_VAULT_V1_PASSWORD_PROOF".utf8)
    private static let vaultAAD = Data("vault:v1".utf8)

    private let store: any VaultStoreDriver
    private let cipher: any VaultCipher
    private let keyDeriver: any VaultKeyDeriver
    private var sessionKey: Data?

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

    /// 锁定并**主动擦除** sessionKey 内存（先 wipe 再置 nil——避免仅置 nil 让派生 key 残留在
    /// 堆内存中，见 review SwiftVault P1#6；`Data.wipe()` 见 `util/Wipe.swift`）。
    public func lock() {
        self.sessionKey?.wipe()
        self.sessionKey = nil
    }

    public func hasPassword() throws -> Bool {
        try self.loadStore().password != nil
    }

    @discardableResult
    public func initializePassword(
        _ password: Data,
        parameters: PasswordKDFParameters = PasswordKDFParameters()
    ) async throws -> Bool {
        var store = try loadStore()
        guard store.password == nil else {
            return false
        }

        let salt = self.randomData(count: 16)
        let key = try await keyDeriver.deriveKeyAsync(
            password: password, salt: salt, parameters: parameters
        )
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

    public func verifyPassword(_ password: Data) async throws -> Bool {
        try await self.deriveAndVerifyKey(password) != nil
    }

    public func unlock(_ password: Data) async throws -> Bool {
        guard let key = try await self.deriveAndVerifyKey(password) else {
            return false
        }
        self.sessionKey = key
        return true
    }

    public func importPrivateKey(address: String, privateKey: Data) throws {
        var store = try loadStore()
        guard !self.containsAddress(address, in: store.keys) else { return }
        try store.keys.append(
            VaultEncryptedRecord(
                address: address,
                payload: self.cipher.encrypt(
                    privateKey, key: self.requireSessionKey(), aad: self.addressAAD(address)
                )
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
        // 单次 load + save（原 importPrivateKey 两次 load/save + 本方法两次 load/save，见 review C-6）
        var store = try loadStore()
        if !self.containsAddress(address, in: store.keys) {
            try store.keys.append(
                VaultEncryptedRecord(
                    address: address,
                    payload: self.cipher.encrypt(
                        privateKey, key: self.requireSessionKey(), aad: self.addressAAD(address)
                    )
                )
            )
        }
        guard !self.containsAddress(address, in: store.mnemonics) else {
            try self.saveStore(store) // key 可能刚追加，仍需落盘
            return
        }
        try store.mnemonics.append(
            VaultMnemonicRecord(
                address: address,
                payload: self.cipher.encrypt(
                    mnemonic, key: self.requireSessionKey(), aad: self.mnemonicAAD(address)
                ),
                derivationPath: pathPrefix,
                language: language
            )
        )
        try self.saveStore(store)
    }

    public func importSecret(address: String, privateKey: Data, secret: Data) throws {
        // 单次 load + save（原 importPrivateKey 两次 load/save + 本方法两次 load/save，见 review C-6）
        var store = try loadStore()
        if !self.containsAddress(address, in: store.keys) {
            try store.keys.append(
                VaultEncryptedRecord(
                    address: address,
                    payload: self.cipher.encrypt(
                        privateKey, key: self.requireSessionKey(), aad: self.addressAAD(address)
                    )
                )
            )
        }
        guard !self.containsAddress(address, in: store.secrets) else {
            try self.saveStore(store) // key 可能刚追加，仍需落盘
            return
        }
        try store.secrets.append(
            VaultEncryptedRecord(
                address: address,
                payload: self.cipher.encrypt(
                    secret, key: self.requireSessionKey(), aad: self.secretAAD(address)
                )
            )
        )
        try self.saveStore(store)
    }

    /// 批量导入私钥（幂等：已存在的地址静默跳过，与 `importPrivateKey` 判重短路一致——
    /// 批量导入是编排路径，单条已存在不应让整批失败，见 review P1#5）。
    public func importPrivateKeys(_ privateKeys: [VaultPrivateKeyImport]) throws {
        guard !privateKeys.isEmpty else {
            return
        }

        var store = try loadStore()
        for item in privateKeys {
            guard !self.containsAddress(item.address, in: store.keys) else {
                continue // 幂等：跳过已存在
            }

            try store.keys.append(
                VaultEncryptedRecord(
                    address: item.address,
                    payload: self.cipher.encrypt(
                        item.privateKey, key: self.requireSessionKey(),
                        aad: self.addressAAD(item.address)
                    )
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

    public func getPrivateKey(address: String, password: Data) async throws -> Data {
        try await self.ensureUnlocked(with: password)
        return try self.getPrivateKeyInternal(address: address)
    }

    public func getMnemonic(address: String, password: Data) async throws -> Data {
        try await self.ensureUnlocked(with: password)
        return try self.getMnemonicInternal(address: address)
    }

    public func getSecret(address: String, password: Data) async throws -> Data {
        try await self.ensureUnlocked(with: password)
        return try self.getSecretInternal(address: address)
    }

    public func getMnemonicLanguage(address: String) throws -> String {
        let store = try loadStore()
        guard let entry = store.mnemonics.first(where: { $0.matches(address: address) }) else {
            throw VaultError.mnemonicNotFound
        }
        return entry.language
    }

    public func removeAddress(address: String, password: Data) async throws {
        try await self.ensureUnlocked(with: password)
        try self.removeAddressUnlocked(address: address)
    }

    /// 已解锁路径：调用方已 `unlock`（密码已验证），不再二次 KDF（见 review B-3：
    /// `AccountManager.removeAccount` 原 `verifyPassword` + `removeAddress` 两次完整派生）。
    public func removeAddressUnlocked(address: String) throws {
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
    ) async throws {
        try await self.ensureUnlocked(with: oldPassword)

        let store = try loadStore()
        let currentKey = try requireSessionKey()
        let newSalt = self.randomData(count: 16)
        let newKey = try await keyDeriver.deriveKeyAsync(
            password: newPassword, salt: newSalt, parameters: parameters
        )

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
            secrets: [],
            biometric: store.biometric // P1#1：改密重建 store 时迁移 biometric（原丢弃）
        )

        for entry in store.keys {
            let plaintext = try cipher.decrypt(
                entry.payload, key: currentKey, aad: self.addressAAD(entry.address)
            )
            try newStore.keys.append(
                VaultEncryptedRecord(
                    address: entry.address,
                    payload: self.cipher.encrypt(
                        plaintext, key: newKey, aad: self.addressAAD(entry.address)
                    )
                )
            )
        }

        for entry in store.mnemonics {
            let plaintext = try cipher.decrypt(
                entry.payload, key: currentKey, aad: self.mnemonicAAD(entry.address)
            )
            try newStore.mnemonics.append(
                VaultMnemonicRecord(
                    address: entry.address,
                    payload: self.cipher.encrypt(
                        plaintext, key: newKey, aad: self.mnemonicAAD(entry.address)
                    ),
                    derivationPath: entry.derivationPath,
                    language: entry.language
                )
            )
        }

        for entry in store.secrets {
            let plaintext = try cipher.decrypt(
                entry.payload, key: currentKey, aad: self.secretAAD(entry.address)
            )
            try newStore.secrets.append(
                VaultEncryptedRecord(
                    address: entry.address,
                    payload: self.cipher.encrypt(
                        plaintext, key: newKey, aad: self.secretAAD(entry.address)
                    )
                )
            )
        }

        try self.saveStore(newStore)
        self.sessionKey = newKey
    }

    public func clearAllData(password: Data) async throws {
        guard try await self.verifyPassword(password) else {
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
        return try self.cipher.decrypt(
            entry.payload, key: self.requireSessionKey(), aad: self.addressAAD(address)
        )
    }

    public func getMnemonicInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.mnemonics.first(where: { $0.matches(address: address) }) else {
            throw VaultError.mnemonicNotFound
        }
        return try self.cipher.decrypt(
            entry.payload, key: self.requireSessionKey(), aad: self.mnemonicAAD(address)
        )
    }

    public func getSecretInternal(address: String) throws -> Data {
        let store = try loadStore()
        guard let entry = store.secrets.first(where: { $0.matches(address: address) }) else {
            throw VaultError.secretNotFound
        }
        return try self.cipher.decrypt(
            entry.payload, key: self.requireSessionKey(), aad: self.secretAAD(address)
        )
    }

    static func defaultStorageURL() -> URL {
        let baseURL =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        return
            baseURL
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

    /// 单次 KDF 派生 + proof 校验（verifyPassword/unlock/ensureUnlocked 共用，见 review B-3）：
    /// 密码正确 → 返回派生 key；错误/未设密码 → nil。
    /// async：KDF（64–256 MiB）走 `deriveKeyAsync`（detached），不阻塞 actor（review P1#3）。
    private func deriveAndVerifyKey(_ password: Data) async throws -> Data? {
        let store = try loadStore()
        guard let envelope = store.password else { return nil }
        let key = try await keyDeriver.deriveKeyAsync(
            password: password,
            salt: envelope.salt,
            parameters: PasswordKDFParameters(
                iterations: envelope.iterations,
                memoryKiB: envelope.memoryKiB,
                parallelism: envelope.parallelism,
                keyByteCount: envelope.keyByteCount
            )
        )
        guard Self.constantTimeEquals(Self.computeProof(for: key), envelope.proof) else {
            return nil
        }
        return key
    }

    private func ensureUnlocked(with password: Data) async throws {
        if self.isUnlocked {
            // 已解锁分支仍校验传入密码（安全契约：密码错误必须报错，见 VaultTests wrongPassword 断言）
            guard try await self.verifyPassword(password) else {
                throw VaultError.wrongPassword
            }
            return
        }

        guard try await self.unlock(password) else {
            throw VaultError.wrongPassword
        }
    }

    private func containsAddress(_ address: String, in entries: [some AddressableRecord]) -> Bool {
        entries.contains(where: { $0.matches(address: address) })
    }

    private func addressAAD(_ address: String) -> Data {
        self.aad(prefix: "address", address: address)
    }

    private func mnemonicAAD(_ address: String) -> Data {
        self.aad(prefix: "mnemonic", address: address)
    }

    private func secretAAD(_ address: String) -> Data {
        self.aad(prefix: "secret", address: address)
    }

    /// 按记录类型区分的 AAD 前缀（三类记录共用一个构造，见跨模块重复 2.2）。
    private func aad(prefix: String, address: String) -> Data {
        Data("\(prefix):\(address.normalizedAddress)".utf8)
    }

    /// 密码学随机数（KDF salt 等必须用 CSPRNG；批量生成而非逐字节 `UInt8.random`）。
    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    private static func computeProof(for key: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: self.proofDomainSeparator, using: SymmetricKey(data: key)
        )
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
