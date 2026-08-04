import Foundation

#if canImport(Tink)
    import Tink

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
            try self.registerAead()
            let handle = try loadOrCreateHandle()
            return try TINKAeadFactory.primitive(with: handle)
        }

        private func registerAead() throws {
            let config = try TINKAeadConfig()
            try TINKConfig.register(config)
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
