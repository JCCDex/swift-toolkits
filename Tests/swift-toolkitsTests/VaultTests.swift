import Foundation
import Testing
@testable import SwiftVault

@Test func vaultRepositorySingletonIsCached() {
    let first = VaultRepository.get()
    let second = VaultRepository.get()

    #expect(first === second)
}

@Test func initializeAndVerifyPassword() async throws {
    let repo = makeRepository()
    let password = Data("123456789ab@][".utf8)
    let newPassword = Data("1234".utf8)

    #expect(!(try await repo.verifyPassword(password)))
    #expect(try await repo.initializePassword(password))
    #expect(try await repo.verifyPassword(password))
    #expect(!(try await repo.initializePassword(newPassword)))
    #expect(try await repo.verifyPassword(password))
    #expect(!(try await repo.verifyPassword(newPassword)))
}

@Test func importMnemonicDuplicateAddressDoesNothing() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let originalMnemonic = Data("evolve paddle gun glance swap clarify shoe youth sweet air change chunk".utf8)
    let originalPrivateKey = Data("48EF9848FB097FFD086E38B9EF54606E17CC77FBC89B158E270B8D0B13A45417".utf8)
    let address = "0XDUP_MNEMONIC_TEST"

    // First import
    try await repo.importMnemonic(address: address, mnemonic: originalMnemonic, privateKey: originalPrivateKey)
    #expect(try await repo.getMnemonic(address: address, password: password) == originalMnemonic)

    // Duplicate import with different data should be silently ignored
    let fakeMnemonic = Data("fake mnemonic words here twelve".utf8)
    let fakePrivateKey = Data("fakekey".utf8)
    try await repo.importMnemonic(address: address, mnemonic: fakeMnemonic, privateKey: fakePrivateKey)

    // Original data must be preserved
    #expect(try await repo.getMnemonic(address: address, password: password) == originalMnemonic)
    #expect(try await repo.getPrivateKey(address: address, password: password) == originalPrivateKey)
}

@Test func importMnemonicDuplicateAddressCaseInsensitive() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let mnemonic = Data("evolve paddle gun glance swap clarify shoe youth sweet air change chunk".utf8)
    let privateKey = Data("48EF9848FB097FFD086E38B9EF54606E17CC77FBC89B158E270B8D0B13A45417".utf8)
    let address = "0xCaseSensitive"

    try await repo.importMnemonic(address: address, mnemonic: mnemonic, privateKey: privateKey)
    #expect(try await repo.addressInMnemonics(address))

    // Same address, different case — should be deduplicated
    try await repo.importMnemonic(address: address.uppercased(), mnemonic: Data("other".utf8), privateKey: Data("other".utf8))
    #expect(try await repo.getMnemonic(address: address, password: password) == mnemonic)
}

@Test func importSecretDuplicateAddressDoesNothing() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let originalPrivateKey = Data("c626df52d7e76721aaae04cf5ce188e53f73369afc8767b1889e2b0cbd599766".utf8)
    let originalSecret = Data("original-secret".utf8)
    let address = "0XDUP_SECRET_TEST"

    // First import
    try await repo.importSecret(address: address, privateKey: originalPrivateKey, secret: originalSecret)
    #expect(try await repo.getSecret(address: address, password: password) == originalSecret)

    // Duplicate import with different data should be silently ignored
    let fakeSecret = Data("fake-secret".utf8)
    let fakePrivateKey = Data("fakekey".utf8)
    try await repo.importSecret(address: address, privateKey: fakePrivateKey, secret: fakeSecret)

    // Original data must be preserved
    #expect(try await repo.getSecret(address: address, password: password) == originalSecret)
    #expect(try await repo.getPrivateKey(address: address, password: password) == originalPrivateKey)
}

@Test func importSecretDuplicateAddressCaseInsensitive() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let privateKey = Data("c626df52d7e76721aaae04cf5ce188e53f73369afc8767b1889e2b0cbd599766".utf8)
    let secret = Data("test-secret".utf8)
    let address = "0xCaseSensitiveSecret"

    try await repo.importSecret(address: address, privateKey: privateKey, secret: secret)
    #expect(try await repo.addressInSecrets(address))

    // Same address, different case — should be deduplicated
    try await repo.importSecret(address: address.uppercased(), privateKey: Data("other".utf8), secret: Data("other".utf8))
    #expect(try await repo.getSecret(address: address, password: password) == secret)
}

@Test func importMnemonicAndReadBack() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let mnemonic = Data("evolve paddle gun glance swap clarify shoe youth sweet air change chunk".utf8)
    let privateKey = Data("48EF9848FB097FFD086E38B9EF54606E17CC77FBC89B158E270B8D0B13A45417".utf8)
    let address = "0X6DB849ED4CE8FE95044BFFBFE4D291AF34B4445D"

    try await repo.importMnemonic(address: address, mnemonic: mnemonic, privateKey: privateKey)

    #expect(try await repo.getPrivateKey(address: address, password: password) == privateKey)
    #expect(try await repo.getMnemonicLanguage(address: address) == "english")
    #expect(try await repo.getMnemonic(address: address, password: password) == mnemonic)

    try await repo.importMnemonic(address: address.lowercased(), mnemonic: Data("a".utf8), privateKey: Data("b".utf8))
    #expect(try await repo.getPrivateKey(address: address.lowercased(), password: password) == privateKey)
    #expect(try await repo.getMnemonic(address: address.lowercased(), password: password) == mnemonic)

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.getPrivateKey(address: address, password: Data("1".utf8))
    }
    await #expect(throws: VaultError.wrongPassword) {
        try await repo.getMnemonic(address: address, password: Data("1".utf8))
    }
}

@Test func importChineseMnemonicAndPreserveLanguage() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let mnemonic = Data("贯 致 拌 龄 片 题 桑 耗 及 同 巨 级".utf8)
    let privateKey = Data("00CBB12FC77B8CFCE7ECB30428E4C2095D317CB285F143C147305C7580DE067367".utf8)
    let address = "JN2NEAIZPNYHYBFUDZBKCPECXDTWBJ6AVA"

    try await repo.importMnemonic(
        address: address,
        mnemonic: mnemonic,
        privateKey: privateKey,
        pathPrefix: "m/44'/315'/0'/0/0",
        language: "chinese_simplified"
    )

    #expect(try await repo.getPrivateKey(address: address, password: password) == privateKey)
    #expect(try await repo.getMnemonic(address: address, password: password) == mnemonic)
    #expect(try await repo.getMnemonicLanguage(address: address) == "chinese_simplified")

    try await repo.importMnemonic(
        address: address.lowercased(),
        mnemonic: Data("测试".utf8),
        privateKey: Data("test".utf8),
        language: "chinese_simplified"
    )
    #expect(try await repo.getMnemonic(address: address.lowercased(), password: password) == mnemonic)
}

@Test func importChineseMnemonicSubAccount() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let mnemonic = Data("贯 致 拌 龄 片 题 桑 耗 及 同 巨 级".utf8)
    let privateKey = Data("00403D510E3864CAA16F00BE92782F130B3F4215369C281B963682E268BC0DF309".utf8)
    let address = "0XED789A614C3844F4F67D333608530D62303C97C6"

    try await repo.importMnemonic(
        address: address,
        mnemonic: mnemonic,
        privateKey: privateKey,
        pathPrefix: "m/44'/60'/0'/0/0",
        language: "chinese_simplified"
    )

    #expect(try await repo.getMnemonicLanguage(address: address) == "chinese_simplified")
    #expect(try await repo.getPrivateKey(address: address, password: password) == privateKey)
    #expect(try await repo.getMnemonic(address: address, password: password) == mnemonic)
}

@Test func importPrivateKeyAndBatchImportDeduplicates() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let privateKey = Data("000E92D1F81827F19D1D1EF46AE4608DD5F5AD658ED973BABE631D279BFC4B0FF3".utf8)
    let address = "JHBAZM_CMDN6865DFFWMP6GI8ZQENEEPFOT".replacingOccurrences(of: "_", with: "")

    try await repo.importPrivateKey(address: address, privateKey: privateKey)
    #expect(try await repo.getPrivateKey(address: address, password: password) == privateKey)

    await #expect(throws: VaultError.mnemonicNotFound) {
        try await repo.getMnemonic(address: address, password: password)
    }
    await #expect(throws: VaultError.privateKeyNotFound) {
        try await repo.getPrivateKey(address: String(address.dropFirst()), password: password)
    }

    let address1 = "0x2995c1376a852e4040caf9dbae2c765e24c37a15"
    let privateKey1 = Data("ca6dbabef201dce8458f29b2290fef4cb80df3e16fef96347c3c250a883e4486".utf8)
    let address2 = "0x5edccedfe9952f5b828937b325bd1f132aa09f60"
    let privateKey2 = Data("8fef3bc906ea19f0348cb44bca851f5459b61e32c5cae445220e2f7066db36d8".utf8)

    try await repo.importPrivateKeys([
        VaultPrivateKeyImport(address: address1, privateKey: privateKey1),
        VaultPrivateKeyImport(address: address1.uppercased(), privateKey: privateKey1),
        VaultPrivateKeyImport(address: address, privateKey: privateKey),
        VaultPrivateKeyImport(address: address2, privateKey: privateKey2)
    ])

    #expect(try await repo.addressInKeys(address1))
    #expect(try await repo.addressInKeys(address2))
    #expect(try await repo.getPrivateKey(address: address1, password: password) == privateKey1)
    #expect(try await repo.getPrivateKey(address: address2, password: password) == privateKey2)
}

@Test func importSecretAndReadBack() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let privateKey = Data("c626df52d7e76721aaae04cf5ce188e53f73369afc8767b1889e2b0cbd599766".utf8)
    let address = "JFM4JTUN3TTS29QCNKDOUBTWQ3PVAPIUBIU"
    let secret = Data("ss6wQ9MMxHwwuzWJXEep5Xc2cfDKj".utf8)

    try await repo.importSecret(address: address, privateKey: privateKey, secret: secret)
    #expect(try await repo.getPrivateKey(address: address, password: password) == privateKey)
    #expect(try await repo.getSecret(address: address, password: password) == secret)

    try await repo.importSecret(address: address.lowercased(), privateKey: Data("a".utf8), secret: Data("b".utf8))
    #expect(try await repo.getPrivateKey(address: address.lowercased(), password: password) == privateKey)
    #expect(try await repo.getSecret(address: address.lowercased(), password: password) == secret)

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.getSecret(address: address, password: Data("1".utf8))
    }
}

@Test func changePasswordMigratesAllEntries() async throws {
    let repo = makeRepository()
    let oldPassword = Data("123456789ab@][".utf8)
    let newPassword = Data("1234".utf8)
    let mnemonic = Data("evolve paddle gun glance swap clarify shoe youth sweet air change chunk".utf8)
    let privateKey = Data("48EF9848FB097FFD086E38B9EF54606E17CC77FBC89B158E270B8D0B13A45417".utf8)
    let address = "0X6DB849ED4CE8FE95044BFFBFE4D291AF34B4445D"
    let privateKey1 = Data("000E92D1F81827F19D1D1EF46AE4608DD5F5AD658ED973BABE631D279BFC4B0FF3".utf8)
    let address1 = "JHBAZMCMDN6865DFFWMP6GI8ZQENEEPFOT"
    let address2 = "JFM4JTUN3TTS29QCNKDOUBTWQ3PVAPIUBIU"
    let secret = Data("ss6wQ9MMxHwwuzWJXEep5Xc2cfDKj".utf8)
    let chineseMnemonic = Data("贯 致 拌 龄 片 题 桑 耗 及 同 巨 级".utf8)
    let chineseAddress = "JN2NEAIZPNYHYBFUDZBKCPECXDTWBJ6AVA"
    let chineseAddress1 = "0XED789A614C3844F4F67D333608530D62303C97C6"

    _ = try await repo.initializePassword(oldPassword)
    try await repo.importMnemonic(address: address, mnemonic: mnemonic, privateKey: privateKey)
    try await repo.importPrivateKey(address: address1, privateKey: privateKey1)
    try await repo.importSecret(address: address2, privateKey: privateKey, secret: secret)
    try await repo.importMnemonic(address: chineseAddress, mnemonic: chineseMnemonic, privateKey: privateKey, pathPrefix: "m/44'/315'/0'/0/0", language: "chinese_simplified")
    try await repo.importMnemonic(address: chineseAddress1, mnemonic: chineseMnemonic, privateKey: privateKey1, pathPrefix: "m/44'/60'/0'/0/0", language: "chinese_simplified")

    try await repo.changePassword(oldPassword: oldPassword, newPassword: newPassword)

    #expect(try await repo.getPrivateKey(address: address.lowercased(), password: newPassword) == privateKey)
    #expect(try await repo.getMnemonic(address: address.lowercased(), password: newPassword) == mnemonic)
    #expect(try await repo.getPrivateKey(address: address1.lowercased(), password: newPassword) == privateKey1)
    #expect(try await repo.getSecret(address: address2.lowercased(), password: newPassword) == secret)
    #expect(try await repo.getMnemonic(address: chineseAddress.lowercased(), password: newPassword) == chineseMnemonic)
    #expect(try await repo.getMnemonic(address: chineseAddress1.lowercased(), password: newPassword) == chineseMnemonic)

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.changePassword(oldPassword: oldPassword, newPassword: newPassword)
    }
}

@Test func removeAddressRemovesAllAssociatedRecords() async throws {
    let repo = try await populatedRepositoryForRemovalTests()
    let password = Data("1234".utf8)
    let address = "0X6DB849ED4CE8FE95044BFFBFE4D291AF34B4445D"
    let address1 = "JHBAZMCMDN6865DFFWMP6GI8ZQENEEPFOT"
    let address2 = "JFM4JTUN3TTS29QCNKDOUBTWQ3PVAPIUBIU"
    let chineseAddress = "JN2NEAIZPNYHYBFUDZBKCPECXDTWBJ6AVA"
    let chineseAddress1 = "0XED789A614C3844F4F67D333608530D62303C97C6"

    let wallets = try await repo.listAccounts()
    #expect(Set(wallets) == Set([address, chineseAddress, chineseAddress1, address1, address2]))

    try await repo.removeAddress(address: address.lowercased(), password: password)
    #expect(Set(try await repo.listAccounts()) == Set([chineseAddress, chineseAddress1, address1, address2]))

    try await repo.removeAddress(address: chineseAddress.lowercased(), password: password)
    try await repo.removeAddress(address: chineseAddress1.lowercased(), password: password)
    try await repo.removeAddress(address: address1.lowercased(), password: password)
    try await repo.removeAddress(address: address2.lowercased(), password: password)
    #expect((try await repo.listAccounts()).isEmpty)

    await #expect(throws: VaultError.mnemonicNotFound) { try await repo.getMnemonic(address: address, password: password) }
    await #expect(throws: VaultError.privateKeyNotFound) { try await repo.getPrivateKey(address: address, password: password) }
    await #expect(throws: VaultError.secretNotFound) { try await repo.getSecret(address: address2, password: password) }
    await #expect(throws: VaultError.mnemonicNotFound) { try await repo.getMnemonic(address: chineseAddress, password: password) }
    await #expect(throws: VaultError.wrongPassword) { try await repo.removeAddress(address: address1.lowercased(), password: Data("1".utf8)) }
}

@Test func listAccountsAndHasPassword() async throws {
    let repo = makeRepository()
    let password = Data("vault-pass".utf8)
    let address = "0XABC123"
    let privateKey = Data("deadbeef".utf8)

    _ = try await repo.initializePassword(password)
    try await repo.importPrivateKey(address: address, privateKey: privateKey)

    #expect(try await repo.hasPassword())
    #expect((try await repo.listAccounts()).contains(address))
}

@Test func biometricLifecycle() async throws {
    let repo = makeRepository()

    #expect(!(try await repo.hasBiometric()))
    await #expect(throws: VaultError.biometricNotFound) { try await repo.getBiometric() }

    let iv = Data("bio-iv".utf8)
    let ciphertext = Data("bio-ciphertext".utf8)
    try await repo.updateBiometric(ciphertext: ciphertext, iv: iv)

    #expect(try await repo.hasBiometric())
    let biometric = try await repo.getBiometric()
    #expect(biometric.iv == iv)
    #expect(biometric.ciphertext == ciphertext)

    try await repo.clearBiometric()
    #expect(!(try await repo.hasBiometric()))
    await #expect(throws: VaultError.biometricNotFound) { try await repo.getBiometric() }
}

@Test func isUnlockedAfterInitLockUnlockCycle() async throws {
    let repo = makeRepository()
    let password = Data("123456789ab@][".utf8)

    try await repo.clearAllData()
    _ = try await repo.initializePassword(password)
    #expect(await repo.isUnlocked)
    await repo.lock()
    #expect(!(await repo.isUnlocked))
    #expect(try await repo.unlock(password))
    #expect(await repo.isUnlocked)
    await repo.lock()
    #expect(!(await repo.isUnlocked))
    #expect(!(try await repo.unlock(Data("wrong".utf8))))
}

@Test func lockUnlockCycleAllowsInternalReadAgain() async throws {
    let repo = makeRepository()
    let password = Data("123456789ab@][".utf8)
    let key = Data("48EF9848FB097FFD086E38B9EF54606E17CC77FBC89B158E270B8D0B13A45417".utf8)
    let address = "0X6DB849ED4CE8FE95044BFFBFE4D291AF34B4445D"

    try await repo.clearAllData()
    _ = try await repo.initializePassword(password)
    try await repo.importPrivateKey(address: address, privateKey: key)
    await repo.lock()

    #expect(!(await repo.isUnlocked))
    #expect(try await repo.unlock(password))
    #expect(try await repo.getPrivateKeyInternal(address: address) == key)
}

@Test func hmacProofVerificationAndPasswordMigration() async throws {
    let repo = makeRepository()
    let oldPassword = Data("oldPassword123".utf8)
    let newPassword = Data("newPassword456".utf8)

    try await repo.clearAllData()
    _ = try await repo.initializePassword(oldPassword)
    #expect(try await repo.verifyPassword(oldPassword))
    #expect(!(try await repo.verifyPassword(Data("wrong".utf8))))
    #expect(try await repo.unlock(oldPassword))
    #expect(await repo.isUnlocked)

    try await repo.changePassword(oldPassword: oldPassword, newPassword: newPassword)
    #expect(try await repo.verifyPassword(newPassword))
    #expect(!(try await repo.verifyPassword(oldPassword)))
}

@Test func clearAllDataPasswordGate() async throws {
    let repo = makeRepository()
    let password = Data("testPassword".utf8)

    try await repo.clearAllData()
    _ = try await repo.initializePassword(password)
    try await repo.clearAllData(password: password)
    #expect(!(try await repo.hasPassword()))

    _ = try await repo.initializePassword(password)
    await #expect(throws: VaultError.wrongPassword) { try await repo.clearAllData(password: Data("wrong".utf8)) }
    try await repo.clearAllData()
    #expect(!(try await repo.hasPassword()))
}

@Test func internalReadRequiresUnlock() async throws {
    let repo = makeRepository()
    let password = Data("testPassword123".utf8)
    let privateKey = Data("48EF9848FB097FFD086E38B9EF54606E17CC77FBC89B158E270B8D0B13A45417".utf8)
    let address = "0X6DB849ED4CE8FE95044BFFBFE4D291AF34B4445D"

    try await repo.clearAllData()
    _ = try await repo.initializePassword(password)
    try await repo.importPrivateKey(address: address, privateKey: privateKey)
    await repo.lock()

    await #expect(throws: VaultError.vaultLocked) { try await repo.getPrivateKeyInternal(address: address) }
    #expect(try await repo.unlock(password))
    #expect(try await repo.getPrivateKeyInternal(address: address) == privateKey)
}

@Test func unlockWorksWithoutPersistedDerivedKey() async throws {
    let repo = makeRepository()
    let password = Data("testPassword123".utf8)

    try await repo.clearAllData()
    _ = try await repo.initializePassword(password)
    await repo.lock()
    #expect(!(await repo.isUnlocked))
    #expect(try await repo.unlock(password))
    #expect(await repo.isUnlocked)
}

@Test func vaultPrivateKeyImportValueSemantics() {
    let left = VaultPrivateKeyImport(address: "0xabc", privateKey: Data([1, 2, 3]))
    let right = VaultPrivateKeyImport(address: "0xabc", privateKey: Data([1, 2, 3]))
    let differentAddress = VaultPrivateKeyImport(address: "0xdef", privateKey: Data([1, 2, 3]))
    let differentKey = VaultPrivateKeyImport(address: "0xabc", privateKey: Data([4, 5, 6]))

    #expect(left == right)
    #expect(left.hashValue == right.hashValue)
    #expect(left != differentAddress)
    #expect(left != differentKey)
}

@Test func wipeClearsByteAndCharacterArrays() {
    var bytes: [UInt8] = [1, 2, 3]
    var chars: [Character] = ["a", "b"]

    bytes.wipe()
    chars.wipe()

    #expect(bytes == [0, 0, 0])
    #expect(chars == [Character(UnicodeScalar(0)), Character(UnicodeScalar(0))])
}

@Test func dataWipeClearsBytes() {
    var data = Data([0xAB, 0xCD, 0xEF])
    data.wipe()
    #expect(data == Data([0, 0, 0]))
}

@Test func wipeOnEmptyArraysIsNoOp() {
    var bytes: [UInt8] = []
    var chars: [Character] = []
    var data = Data()

    bytes.wipe()
    chars.wipe()
    data.wipe()

    #expect(bytes.isEmpty)
    #expect(chars.isEmpty)
    #expect(data.isEmpty)
}

@Test func argon2ChooserReturnsPositiveParameters() {
    let params = Argon2ParamChooser.choose(physicalMemoryBytes: 512 * 1024 * 1024)
    let largeHeapParams = Argon2ParamChooser.choose(preferLargeHeap: true, physicalMemoryBytes: 2 * 1024 * 1024 * 1024)

    #expect(params.iterations > 0)
    #expect(params.memoryKiB > 0)
    #expect(largeHeapParams.iterations > 0)
    #expect(largeHeapParams.memoryKiB > 0)
    #expect(largeHeapParams.parallelism == 1)
}

@Test func protobufSerializerDefaultAndRoundTripEmptyVault() throws {
    let empty = Vault()
    let restored = try Vault(serializedBytes: empty.serializedData())
    #expect(restored == empty)
}

@Test func protobufStoreDriverMissingFileLoadsEmptySnapshot() throws {
    let driver = ProtobufVaultStoreDriver(storageURL: makeTemporaryVaultURL())
    let snapshot = try driver.load()
    #expect(snapshot.password == nil)
    #expect(snapshot.keys.isEmpty)
    #expect(snapshot.mnemonics.isEmpty)
    #expect(snapshot.secrets.isEmpty)
    #expect(snapshot.biometric == nil)
}

#if canImport(Tink)
@Test func tinkCipherUsesOpaqueCiphertextPayload() throws {
    let cipher = TinkVaultCipher(
        keysetName: "com.swifttoolkits.tests.\(UUID().uuidString)",
        persistKeysetInKeychain: false
    )
    let plaintext = Data("tink-roundtrip".utf8)
    let aad = Data("address:0xtink".utf8)

    let payload = try cipher.encrypt(plaintext, key: Data(), aad: aad)

    #expect(payload.iv.isEmpty)
    #expect(!payload.ciphertext.isEmpty)
    #expect(try cipher.decrypt(payload, key: Data(), aad: aad) == plaintext)
}

#if os(iOS)
@Test func tinkProtobufPersistenceUsesOpaqueCiphertextOnIOS() async throws {
    let vaultURL = makeTemporaryVaultURL()
    let repo = VaultRepository(
        storageURL: vaultURL,
        cipher: TinkVaultCipher(
            keysetName: "com.swifttoolkits.tests.pb.\(UUID().uuidString)",
            persistKeysetInKeychain: false
        )
    )
    let password = Data("tink-protobuf".utf8)
    let privateKey = Data("0xopaque".utf8)

    _ = try await repo.initializePassword(password)
    try await repo.importPrivateKey(address: "0xTINKPB", privateKey: privateKey)

    let storedData = try Data(contentsOf: vaultURL)
    let vault = try Vault(serializedBytes: storedData)

    #expect(vault.keys.count == 1)
    #expect(vault.keys[0].iv.isEmpty)
    #expect(!vault.keys[0].ciphertext.isEmpty)
}

@Test func tinkRepositoryRoundTripOnIOS() async throws {
    let keysetName = "com.swifttoolkits.tests.repo.\(UUID().uuidString)"
    let repo = VaultRepository(
        storageURL: makeTemporaryVaultURL(),
        cipher: TinkVaultCipher(keysetName: keysetName, persistKeysetInKeychain: false)
    )
    let password = Data("tink-password".utf8)
    let privateKey = Data("0xtinkprivate".utf8)
    let secret = Data("tink-secret".utf8)

    #expect(try await repo.initializePassword(password))
    try await repo.importSecret(address: "0xTINK", privateKey: privateKey, secret: secret)
    await repo.lock()

    #expect(try await repo.unlock(password))
    #expect(try await repo.getPrivateKey(address: "0xtink", password: password) == privateKey)
    #expect(try await repo.getSecret(address: "0xTINK", password: password) == secret)
}
#endif
#endif

private func makeRepository(cipher: (any VaultCipher)? = nil) -> VaultRepository {
    VaultRepository(storageURL: makeTemporaryVaultURL(), cipher: cipher)
}

// ── Additional branch coverage tests ─────────────────────────────────────────

@Test func unlockReturnsFalseWhenNoPasswordSet() async throws {
    let repo = makeRepository()
    #expect(!(try await repo.unlock(Data("any".utf8))))
}

@Test func importPrivateKeysEmptyArrayDoesNothing() async throws {
    let repo = try await seededRepository()
    try await repo.importPrivateKeys([])
    #expect((try await repo.listAccounts()).isEmpty)
}

@Test func getMnemonicLanguageThrowsForAddressWithoutMnemonic() async throws {
    let repo = try await seededRepository()
    let password = Data("123456789ab@][".utf8)
    let privateKey = Data("key".utf8)

    try await repo.importPrivateKey(address: "0xKEYONLY", privateKey: privateKey)

    await #expect(throws: VaultError.mnemonicNotFound) {
        try await repo.getMnemonicLanguage(address: "0xKEYONLY")
    }
}

@Test func getSecretWithWrongPasswordWhenLockedThrowsWrongPassword() async throws {
    let repo = try await seededRepository()
    let secretKey = Data("c626df52d7e76721aaae04cf5ce188e53f73369afc8767b1889e2b0cbd599766".utf8)
    let secret = Data("my-secret".utf8)
    let address = "0XSECRETTEST"

    try await repo.importSecret(address: address, privateKey: secretKey, secret: secret)
    await repo.lock()
    #expect(!(await repo.isUnlocked))

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.getSecret(address: address, password: Data("wrong".utf8))
    }
}

@Test func getPrivateKeyWithWrongPasswordWhenLockedThrowsWrongPassword() async throws {
    let repo = try await seededRepository()
    let privateKey = Data("test-key".utf8)
    let address = "0XLOCKEDTEST"

    try await repo.importPrivateKey(address: address, privateKey: privateKey)
    await repo.lock()

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.getPrivateKey(address: address, password: Data("wrong".utf8))
    }
}

@Test func getMnemonicWithWrongPasswordWhenLockedThrowsWrongPassword() async throws {
    let repo = try await seededRepository()
    let mnemonic = Data("test mnemonic phrase twelve words".utf8)
    let privateKey = Data("test-key".utf8)
    let address = "0XMNEMONICTEST"

    try await repo.importMnemonic(address: address, mnemonic: mnemonic, privateKey: privateKey)
    await repo.lock()

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.getMnemonic(address: address, password: Data("wrong".utf8))
    }
}

@Test func removeAddressWithWrongPasswordWhenLockedThrowsWrongPassword() async throws {
    let repo = try await seededRepository()
    let privateKey = Data("test-key".utf8)
    let address = "0XREMOVE_TEST"

    try await repo.importPrivateKey(address: address, privateKey: privateKey)
    await repo.lock()

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.removeAddress(address: address, password: Data("wrong".utf8))
    }
}

@Test func changePasswordWithWrongOldPasswordWhenLockedThrowsWrongPassword() async throws {
    let repo = try await seededRepository()
    await repo.lock()

    await #expect(throws: VaultError.wrongPassword) {
        try await repo.changePassword(oldPassword: Data("wrong".utf8), newPassword: Data("new".utf8))
    }
}

#if canImport(CryptoKit)
@Test func cryptoKitCipherThrowsOnTruncatedCiphertext() throws {
    let cipher = CryptoKitVaultCipher()
    let key = Data("test-key-32-bytes-long!!".utf8)
    let aad = Data("test-aad".utf8)

    let payload = VaultSealedPayload(
        iv: Data(repeating: 0, count: 12),
        ciphertext: Data([1, 2, 3]) // too short (< 16 bytes tag)
    )

    #expect(throws: CocoaError.self) {
        try cipher.decrypt(payload, key: key, aad: aad)
    }
}
#endif

private func seededRepository() async throws -> VaultRepository {
    let repo = makeRepository()
    _ = try await repo.initializePassword(Data("123456789ab@][".utf8))
    return repo
}

private func populatedRepositoryForRemovalTests() async throws -> VaultRepository {
    let repo = makeRepository()
    let password = Data("1234".utf8)
    let mnemonic = Data("evolve paddle gun glance swap clarify shoe youth sweet air change chunk".utf8)
    let privateKey = Data("48EF9848FB097FFD086E38B9EF54606E17CC77FBC89B158E270B8D0B13A45417".utf8)
    let address = "0X6DB849ED4CE8FE95044BFFBFE4D291AF34B4445D"
    let privateKey1 = Data("000E92D1F81827F19D1D1EF46AE4608DD5F5AD658ED973BABE631D279BFC4B0FF3".utf8)
    let address1 = "JHBAZMCMDN6865DFFWMP6GI8ZQENEEPFOT"
    let address2 = "JFM4JTUN3TTS29QCNKDOUBTWQ3PVAPIUBIU"
    let secret = Data("ss6wQ9MMxHwwuzWJXEep5Xc2cfDKj".utf8)
    let chineseMnemonic = Data("贯 致 拌 龄 片 题 桑 耗 及 同 巨 级".utf8)
    let chineseAddress = "JN2NEAIZPNYHYBFUDZBKCPECXDTWBJ6AVA"
    let chineseAddress1 = "0XED789A614C3844F4F67D333608530D62303C97C6"

    _ = try await repo.initializePassword(password)
    try await repo.importMnemonic(address: address, mnemonic: mnemonic, privateKey: privateKey)
    try await repo.importPrivateKey(address: address1, privateKey: privateKey1)
    try await repo.importSecret(address: address2, privateKey: privateKey, secret: secret)
    try await repo.importMnemonic(address: chineseAddress, mnemonic: chineseMnemonic, privateKey: privateKey, pathPrefix: "m/44'/315'/0'/0/0", language: "chinese_simplified")
    try await repo.importMnemonic(address: chineseAddress1, mnemonic: chineseMnemonic, privateKey: privateKey1, pathPrefix: "m/44'/60'/0'/0/0", language: "chinese_simplified")
    return repo
}

private func makeTemporaryVaultURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("vault.pb", isDirectory: false)
}