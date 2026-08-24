import SwiftCore
import SwiftWallet

/// 账户编排结果（对齐 Kotlin `AccountOperationResult<T>`；有意不用 Swift `Result`——
/// Success/Error 命名与 Kotlin 逐一对齐，`switch` 分支语义贴近原模块）。
public enum AccountOperationResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(AccountOperationError)
}

extension AccountOperationResult: Equatable where Value: Equatable {}

/// 账户编排错误（对齐 Kotlin `AccountOperationError`）。
public enum AccountOperationError: Error, Equatable, Sendable {
    case addressAlreadyExists
    case accountAlreadyExists
    case rootAccountNotFound
    case passwordRequired
    case wrongPassword(String = "Password is wrong")
    /// 底层错误描述（Kotlin `Failure(cause: Throwable)` 的 message 对应物；不跨模块暴露 Error 装箱）。
    case failure(String)
}

/// HD 钱包导入结果（对齐 Kotlin `ImportHdWalletResult`）。
public struct ImportHdWalletResult: Sendable, Equatable {
    public let rootAccountId: String
    public let children: [HdChildAccountId]

    public init(rootAccountId: String, children: [HdChildAccountId]) {
        self.rootAccountId = rootAccountId
        self.children = children
    }
}

/// HD 子账户标识（对齐 Kotlin `HdChildAccountId`）。
public struct HdChildAccountId: Sendable, Equatable {
    public let chain: ChainType
    public let accountId: String

    public init(chain: ChainType, accountId: String) {
        self.chain = chain
        self.accountId = accountId
    }
}

/// 派生子账户产出（对齐 Kotlin `DerivedSubAccount`；落库由 `importSubAccount` 完成）。
public struct DerivedSubAccount: Sendable, Equatable {
    public let address: String
    public let chain: ChainType
    public let path: Path
    public let rootAccountId: String
    public let keypair: Keypair

    public init(address: String, chain: ChainType, path: Path, rootAccountId: String, keypair: Keypair) {
        self.address = address
        self.chain = chain
        self.path = path
        self.rootAccountId = rootAccountId
        self.keypair = keypair
    }
}
