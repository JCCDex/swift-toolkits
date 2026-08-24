import Foundation
import SwiftCore
import SwiftVault
import SwiftWallet

/// 账户编排器（镜像 Kotlin `AccountManager`）：导入 / 派生 / 删除流程，
/// 依赖 `AccountStore` + `SwiftVault`（密钥落库）+ `SwiftWallet`（地址派生）。
/// 自由线程（非 @MainActor）；`SwiftWallet` 为 @MainActor，经 `await` 跨 actor 调用。
public final class AccountManager: Sendable {
    private let store: any AccountStore
    private let vault: VaultRepository
    private let wallet: any WalletDeriving
    private let deriveGate = AsyncMutex()

    public init(store: any AccountStore, vault: VaultRepository, wallet: any WalletDeriving) {
        self.store = store
        self.vault = vault
        self.wallet = wallet
    }

    // MARK: - 导入

    /// 导入单账户（传统 / HD 子账户共用）：地址判重 → 密钥落 vault → 元数据落 store。
    public func importSingleAccount(
        derived: TraditionalDeriveResult,
        chain: ChainType,
        name: String,
        isHD: Bool,
        parentId: String?
    ) async -> AccountOperationResult<String> {
        await self.runOperation {
            let address: String = derived.address
            if try await self.store.findNonRootAccount(address: address, chain: chain) != nil {
                return .failure(.addressAlreadyExists)
            }

            try await self.persistVault(derived)
            let walletAccount = WalletAccount(
                // id 用默认 UUID（对齐 Kotlin：id 是调用方可控的业务键；判重依赖 address，
                // 见 importSingleAccount 入口的 findNonRootAccount 预检）
                address: address,
                chain: chain,
                name: name,
                isHD: isHD,
                parentId: parentId,
                path: derived.path,
                publicKey: derived.keypair.publicKey
            )
            try await self.store.addAccount(walletAccount)
            return .success(walletAccount.id)
        }
    }

    /// 导入 HD 钱包：根账户（SWTC）+ 各链子账户；可选清空既有数据。
    /// - Parameters:
    ///   - password: vault 为空时初始化密码；vault 已有密码时忽略。
    public func importHdWallet(
        hdResult: GenerateHDWalletResult,
        name: String,
        password: Data?
    ) async -> AccountOperationResult<ImportHdWalletResult> {
        await self.runOperation {

            if try await self.store.findRootAccountByAddress(hdResult.address) != nil {
                return .failure(.accountAlreadyExists)
            }

            if try await !self.vault.hasPassword() {
                guard let password else { return .failure(.passwordRequired) }
                try await self.vault.initializePassword(password)
            }

            // Kotlin 字面根路径 chain=0：仅用于 pathPrefix（m/44'/0'/0'/0/0），path.chain 不落库
            let rootPath = Path(chain: 0, account: 0, change: 0, index: 0)
            try await self.vault.importMnemonic(
                address: hdResult.address,
                mnemonic: Data(hdResult.mnemonic.utf8),
                privateKey: Data(hdResult.keypair.privateKey.utf8),
                pathPrefix: rootPath.derivationPath,
                language: hdResult.language
            )

            let rootAccount = WalletAccount(
                address: hdResult.address,
                chain: .swtc,
                name: name,
                isHD: true,
                parentId: nil,
                path: rootPath,
                publicKey: hdResult.keypair.publicKey
            )
            var accounts = [rootAccount]
            var childIds: [HdChildAccountId] = []
            var keys: [VaultPrivateKeyImport] = []

            for sub in hdResult.accounts {
                guard let chainType = ChainType.fromBip44Code(sub.chain) else { continue } // 未知链整体跳过
                keys.append(VaultPrivateKeyImport(address: sub.address, privateKey: Data(sub.keypair.privateKey.utf8)))

                if try await self.store.findNonRootAccount(address: sub.address, chain: chainType) != nil {
                    continue
                }
                let child = WalletAccount(
                    address: sub.address,
                    chain: chainType,
                    name: "\(chainType.label)-HD",
                    isHD: true,
                    parentId: rootAccount.id,
                    path: sub.path,
                    publicKey: sub.keypair.publicKey
                )
                accounts.append(child)
                childIds.append(HdChildAccountId(chain: chainType, accountId: child.id))
            }

            try await self.vault.importPrivateKeys(keys)
            try await self.store.addAccounts(accounts)

            return .success(ImportHdWalletResult(rootAccountId: rootAccount.id, children: childIds))
        }
    }

    /// 落库已派生的子账户（deriveSubAccount 产出；私钥已在派生阶段入 vault，此处不碰私钥）。
    public func importSubAccount(
        derived: DerivedSubAccount,
        name: String
    ) async -> AccountOperationResult<String> {
        await self.runOperation {
            if try await self.store.findById(derived.rootAccountId) == nil {
                return .failure(.rootAccountNotFound)
            }
            return await self.importSingleAccount(
                derived: TraditionalDeriveResult(
                    address: derived.address,
                    keypair: Keypair(privateKey: "", publicKey: derived.publicKey),
                    path: derived.path
                ),
                chain: derived.chain,
                name: name,
                isHD: true,
                parentId: derived.rootAccountId
            )
        }
    }

    // MARK: - 派生

    /// 从 HD 根账户派生子账户（链式 Task 串行互斥；vault 解锁态副作用见 Account-Swift 04 坑 #6）。
    public func deriveSubAccount(
        chain: ChainType,
        rootAccountId: String,
        password: Data,
        index: Int? = nil
    ) async -> AccountOperationResult<DerivedSubAccount> {
        await self.deriveGate.withLock {
            await self.runOperation {
                guard try await self.store.findById(rootAccountId) != nil else {
                    return .failure(.rootAccountNotFound)
                }
                guard let root = try await self.store.findById(rootAccountId) else {
                    return .failure(.rootAccountNotFound)
                }

                let mnemonic = try await self.vault.getMnemonic(address: root.address, password: password)
                let language = try await self.vault.getMnemonicLanguage(address: root.address)

                var deriveIndex: Int = if let index {
                    index
                } else {
                    try await self.store.getMaxIndexByChain(parentId: rootAccountId, chain: chain) + 1
                }
                var subWallet = try await self.wallet.deriveChild(
                    mnemonic: String(decoding: mnemonic, as: UTF8.self),
                    chain: chain.bip44Code,
                    account: 0,
                    change: 0,
                    index: deriveIndex,
                    language: language
                )
                while index == nil {
                    let occupied = await (try? self.store.findNonRootAccount(address: subWallet.address, chain: chain)) != nil
                    if !occupied {
                        break
                    }
                    deriveIndex += 1
                    subWallet = try await self.wallet.deriveChild(
                        mnemonic: String(decoding: mnemonic, as: UTF8.self),
                        chain: chain.bip44Code,
                        account: 0,
                        change: 0,
                        index: deriveIndex,
                        language: language
                    )
                }

                try await self.vault.importPrivateKey(address: subWallet.address, privateKey: Data(subWallet.keypair.privateKey.utf8))

                return .success(DerivedSubAccount(
                    address: subWallet.address,
                    chain: chain,
                    path: subWallet.path,
                    rootAccountId: root.id,
                    publicKey: subWallet.keypair.publicKey
                ))
            }
        }
    }

    // MARK: - 删除

    /// 删除账户：先验密码；账户不存在 → 幂等成功；同地址仅此一条时同步删 vault 密钥。
    /// 单次 KDF：`unlock`（校验 + 建立 sessionKey）→ `removeAddressUnlocked`（已解锁路径不再派生，
    /// 见 review B-3——原 `verifyPassword` + `removeAddress` 两次完整派生）。
    public func removeAccount(
        accountId: String,
        password: Data
    ) async -> AccountOperationResult<Void> {
        await self.runOperation {
            if try await !self.vault.unlock(password) {
                return .failure(.wrongPassword())
            }
            guard let account = try await self.store.findById(accountId) else {
                return .success(())
            }
            let count = try await self.store.getSameAccountsCount(address: account.address)
            try await self.store.removeAccount(accountId: account.id)
            if count == 1 {
                try await self.vault.removeAddressUnlocked(address: account.address)
            }
            return .success(())
        }
    }

    /// 清空 vault 与账户；vault 已有密码时须当前密码（无密码 = 无数据，直接清账户）。
    public func clearWalletData(password: Data) async -> AccountOperationResult<Void> {
        await self.runOperation {
            do {
                if try await self.vault.hasPassword() {
                    try await self.vault.clearAllData(password: password)
                }
            } catch {
                return .failure(.wrongPassword())
            }
            try await self.store.clearAllAccounts()
            return .success(())
        }
    }

    // MARK: - 内部

    /// 密钥落库（mnemonic / secret / privateKey 三选一，对齐 Kotlin persistVaultMaterial）。
    ///
    /// vault 写入失败必须向上抛（P0-5：曾用 `try?` 吞错，导致 `importSingleAccount` 报成功
    /// 但私钥从未入库——账户元数据存在却无法签名）。`runOperation` 负责把错误映射为 failure。
    private func persistVault(_ derived: TraditionalDeriveResult) async throws {
        let keypair = derived.keypair
        if let mnemonic = derived.mnemonic {
            try await self.vault.importMnemonic(
                address: derived.address,
                mnemonic: Data(mnemonic.value.utf8),
                privateKey: Data(keypair.privateKey.utf8),
                pathPrefix: derived.path?.derivationPath ?? "",
                language: mnemonic.language
            )
        } else if let secret = derived.secret {
            try await self.vault.importSecret(
                address: derived.address,
                privateKey: Data(keypair.privateKey.utf8),
                secret: Data(secret.utf8)
            )
        } else {
            try await self.vault.importPrivateKey(address: derived.address, privateKey: Data(keypair.privateKey.utf8))
        }
    }

    private func runOperation<T>(_ block: () async throws -> AccountOperationResult<T>) async -> AccountOperationResult<T> {
        do {
            return try await block()
        } catch {
            return .failure(.failure(String(describing: error)))
        }
    }
}
