import Foundation

#if canImport(Tink)
    import Tink

    /// @unchecked Sendable：本实现仅供 `VaultRepository` actor 内部使用——encrypt/decrypt
    /// 均在 actor 串行执行，可变 cachedHandle（:51/:57/:60）不会并发访问（见 review 三、Sendable 审计）。
    public final class TinkVaultCipher: VaultCipher, @unchecked Sendable {
        private let keysetName: String
        private let accessGroup: String?
        private let persistKeysetInKeychain: Bool
        private var cachedHandle: TINKKeysetHandle?

        public init(
            keysetName: String = "com.swifttoolkits.vault.aead",
            accessGroup: String? = nil,
            persistKeysetInKeychain: Bool = true
        ) {
            self.keysetName = keysetName
            self.accessGroup = accessGroup
            self.persistKeysetInKeychain = persistKeysetInKeychain
        }

        public func encrypt(_ plaintext: Data, key _: Data, aad: Data) throws -> VaultSealedPayload {
            let primitive = try loadOrCreatePrimitive()
            let ciphertext = try primitive.encrypt(plaintext, withAdditionalData: aad)
            return VaultSealedPayload(iv: Data(), ciphertext: ciphertext)
        }

        public func decrypt(_ payload: VaultSealedPayload, key _: Data, aad: Data) throws -> Data {
            let primitive = try loadOrCreatePrimitive()
            return try primitive.decrypt(payload.ciphertext, withAdditionalData: aad)
        }

        private func loadOrCreatePrimitive() throws -> TINKAead {
            try Self.ensureAeadRegistered() // 单次注册（原每次 encrypt/decrypt 都 register，见 review 补充细节）
            let handle = try loadOrCreateHandle()
            return try TINKAeadFactory.primitive(with: handle)
        }

        /// Tink 算法注册只需一次（重复 register 同类会抛错/浪费）；static 惰性 + 锁保证幂等。
        private static func ensureAeadRegistered() throws {
            guard !self.aeadRegistered else { return }
            let config = try TINKAeadConfig()
            try TINKConfig.register(config)
            Self.aeadRegistered = true
        }

        /// nonisolated(unsafe)：注册标记是进程级一次性状态，NSLock 串行化「检查-注册-置位」
        /// 原子序列；与 `SsrfGuard.enabled`（DEBUG 一次性）同款模式，见 review 三、Sendable 审计。
        private static let aeadRegisteredLock = NSLock()
        private nonisolated(unsafe) static var _aeadRegistered = false
        private static var aeadRegistered: Bool {
            get { aeadRegisteredLock.withLock { Self._aeadRegistered } }
            set { aeadRegisteredLock.withLock { Self._aeadRegistered = newValue } }
        }

        private func loadOrCreateHandle() throws -> TINKKeysetHandle {
            if let cachedHandle {
                return cachedHandle
            }

            if !self.persistKeysetInKeychain {
                let handle = try createHandle(persist: false)
                cachedHandle = handle
                return handle
            }

            if let handle = try? loadHandleFromKeychain() {
                cachedHandle = handle
                return handle
            }
            let handle = try createHandle(persist: true)
            cachedHandle = handle
            return handle
        }

        private func loadHandleFromKeychain() throws -> TINKKeysetHandle {
            try TINKKeysetHandle(fromKeychainWithName: self.keysetName, accessGroup: self.accessGroup)
        }

        private func createHandle(persist: Bool) throws -> TINKKeysetHandle {
            let template = try TINKAeadKeyTemplate(keyTemplate: .TINKAes256Gcm)
            let handle = try TINKKeysetHandle(keyTemplate: template)
            if persist {
                _ = try handle.writeToKeychain(withName: self.keysetName, accessGroup: self.accessGroup, overwrite: false)
            }
            return handle
        }
    }

#endif
