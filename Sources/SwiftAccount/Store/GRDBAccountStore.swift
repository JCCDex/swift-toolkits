import Foundation
import GRDB
import OSLog
import SwiftCore

/// GRDB 实现（对应 Kotlin `RoomAccountStore` + `AccountRoomDatabase`）：
/// - `accounts` 表：`id` 文本主键 / `address` / `chain`（Int64 = BIP44 code）/ `name` / `isHD` /
///   `parentId` / `pathAccount?` / `pathChange?` / `pathIndex?` / `publicKey`；
/// - `current_account` 表：固定 `id = 1` 单行 + `accountId`（NOT NULL，删除 current 时删行、不置空）；
/// - 地址写入归一为小写、查询不再 `LOWER()`（v2 起；对齐 Kotlin DAO `COLLATE NOCASE` 语义，
///   且让 `idx_accounts_address` 生效，见 review 存储/索引项 C-1）；
/// - `addAccount`/`addAccounts` 普通 INSERT（冲突抛错，对齐 Kotlin `@Insert` ABORT）；
///   `current_account` 用 `ON CONFLICT(id) DO UPDATE`（固定单行）。
/// @unchecked Sendable：持有的 DatabasePool 线程安全（GRDB 官方文档），见 review 三、Sendable 审计。
public final class GRDBAccountStore: AccountStore, @unchecked Sendable {
    private let database: DatabasePool

    public init(database: DatabasePool) throws {
        self.database = database
        try Self.migrate(database)
    }

    private static func migrate(_ database: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "accounts") { t in
                t.column("id", .text).primaryKey()
                t.column("address", .text).notNull()
                t.column("chain", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("isHD", .boolean).notNull()
                t.column("parentId", .text)
                t.column("pathAccount", .integer)
                t.column("pathChange", .integer)
                t.column("pathIndex", .integer)
                t.column("publicKey", .text).notNull()
            }
            try db.create(table: "current_account") { t in
                t.column("id", .integer).primaryKey()
                t.column("accountId", .text).notNull()
            }
            try db.create(index: "idx_accounts_address", on: "accounts", columns: ["address"])
            try db.create(index: "idx_accounts_parent", on: "accounts", columns: ["parentId"])
        }
        // v2（review C-1）：旧行地址统一小写（新写入在 AccountRecord 归一），
        // 查询去掉 LOWER() 使 idx_accounts_address 生效。
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "UPDATE accounts SET address = LOWER(address)")
        }
        // v3（review SwiftAccount P1#7）：(address, chain) 唯一索引——预检 + 插入非原子，
        // 并发导入同地址会重复入库；v2 归一后 address 已小写，可建唯一索引。
        migrator.registerMigration("v3") { db in
            try db.create(index: "idx_accounts_address_chain", on: "accounts", columns: ["address", "chain"], unique: true)
        }
        try migrator.migrate(database)
    }

    // MARK: - 观察

    public func observeAccounts() -> AsyncStream<[WalletAccount]> {
        self.stream(ValueObservation.tracking { db in
            try AccountRecord.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY chain, address")
        }) { $0.map(\.account) }
    }

    public func observeCurrentAccount() -> AsyncStream<WalletAccount?> {
        self.stream(ValueObservation.tracking { db in
            guard let accountId = try CurrentAccountRecord.fetchOne(db)?.accountId else { return nil }
            return try AccountRecord.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [accountId])?.account
        }) { $0 }
    }

    public func observeRootHDAccounts() -> AsyncStream<[WalletAccount]> {
        self.stream(ValueObservation.tracking { db in
            try AccountRecord.fetchAll(
                db,
                sql: "SELECT * FROM accounts WHERE isHD = 1 AND parentId IS NULL ORDER BY chain, address"
            ).map(\.account)
        }) { $0 }
    }

    public func observeSubHDAccounts() -> AsyncStream<[WalletAccount]> {
        self.stream(ValueObservation.tracking { db in
            try AccountRecord.fetchAll(
                db,
                sql: "SELECT * FROM accounts WHERE isHD = 1 AND parentId IS NOT NULL ORDER BY chain, address"
            ).map(\.account)
        }) { $0 }
    }

    public func observeTraditionalAccounts() -> AsyncStream<[WalletAccount]> {
        self.stream(ValueObservation.tracking { db in
            try AccountRecord.fetchAll(
                db,
                sql: "SELECT * FROM accounts WHERE isHD = 0 ORDER BY chain, address"
            ).map(\.account)
        }) { $0 }
    }

    public func observeAccounts(chain: ChainType) -> AsyncStream<[WalletAccount]> {
        self.stream(ValueObservation.tracking { db in
            try AccountRecord.fetchAll(
                db,
                sql: "SELECT * FROM accounts WHERE chain = ? ORDER BY address",
                arguments: [chain.bip44Code]
            ).map(\.account)
        }) { $0 }
    }

    public func observeSubAccounts(of parentId: String) -> AsyncStream<[WalletAccount]> {
        self.stream(ValueObservation.tracking { db in
            try AccountRecord.fetchAll(
                db,
                sql: "SELECT * FROM accounts WHERE parentId = ? ORDER BY chain, address",
                arguments: [parentId]
            ).map(\.account)
        }) { $0 }
    }

    // MARK: - 写

    public func addAccount(_ account: WalletAccount) async throws {
        try await self.database.write { db in
            var record = AccountRecord(account: account)
            try record.insert(db)
        }
    }

    public func addAccounts(_ accounts: [WalletAccount]) async throws {
        guard !accounts.isEmpty else { return }
        try await self.database.write { db in
            for account in accounts {
                var record = AccountRecord(account: account)
                try record.insert(db)
            }
        }
    }

    public func removeAccount(accountId: String) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM current_account WHERE accountId = ?", arguments: [accountId]) // 对齐 Kotlin clearIfCurrent
        }
    }

    public func setCurrentAccount(accountId: String) async throws {
        try await self.database.write { db in
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts WHERE id = ?", arguments: [accountId]) ?? 0
            guard exists > 0 else { throw AccountStoreError.accountNotFound(accountId) }
            var current = CurrentAccountRecord(id: 1, accountId: accountId)
            try current.upsert(db)
        }
    }

    public func updateAccountName(accountId: String, name: String) async throws {
        try await self.database.write { db in
            try Self.requireUpdate(db, sql: "UPDATE accounts SET name = ? WHERE id = ?", arguments: [name, accountId], accountId: accountId)
        }
    }

    public func updateAccountNameByAddress(address: String, name: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE accounts SET name = ? WHERE address = ?",
                arguments: [name, address.normalizedAddress]
            )
        }
    }

    public func updatePublicKey(accountId: String, publicKey: String) async throws {
        try await self.database.write { db in
            try Self.requireUpdate(db, sql: "UPDATE accounts SET publicKey = ? WHERE id = ?", arguments: [publicKey, accountId], accountId: accountId)
        }
    }

    public func updateParentId(_ accountId: String, parentId: String) async throws {
        try await self.database.write { db in
            try Self.requireUpdate(db, sql: "UPDATE accounts SET parentId = ? WHERE id = ?", arguments: [parentId, accountId], accountId: accountId)
        }
    }

    /// UPDATE 影响行数检查（review SwiftAccount P1#9）：更新不存在的 id 静默成功 →
    /// 0 行则抛 `accountNotFound`（对齐 Kotlin Room `@Update` 行数返回，不再无声吞掉）。
    /// GRDB 的 `Statement.execute` 无行数返回，用 SQLite `changes()` 取本次变更行数。
    private static func requireUpdate(
        _ db: Database,
        sql: String,
        arguments: StatementArguments,
        accountId: String
    ) throws {
        try db.execute(sql: sql, arguments: arguments)
        let changed = try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        guard changed > 0 else { throw AccountStoreError.accountNotFound(accountId) }
    }

    public func clearAllAccounts() async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM accounts")
            try db.execute(sql: "DELETE FROM current_account")
        }
    }

    // MARK: - 查

    public func findById(_ id: String) async throws -> WalletAccount? {
        try await self.database.read { db in
            try AccountRecord.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [id])?.account
        }
    }

    public func findByAddress(_ address: String, chain: ChainType) async throws -> WalletAccount? {
        try await self.database.read { db in
            try AccountRecord.fetchOne(
                db,
                sql: "SELECT * FROM accounts WHERE address = ? AND chain = ?",
                arguments: [address.normalizedAddress, chain.bip44Code]
            )?.account
        }
    }

    public func findByAddress(_ address: String) async throws -> WalletAccount? {
        try await self.database.read { db in
            try AccountRecord.fetchOne(
                db,
                sql: "SELECT * FROM accounts WHERE address = ?",
                arguments: [address.normalizedAddress]
            )?.account
        }
    }

    public func findRootAccountByAddress(_ address: String) async throws -> WalletAccount? {
        try await self.database.read { db in
            try AccountRecord.fetchOne(
                db,
                sql: "SELECT * FROM accounts WHERE address = ? AND isHD = 1 AND parentId IS NULL",
                arguments: [address.normalizedAddress]
            )?.account
        }
    }

    public func findNonRootAccount(address: String, chain: ChainType) async throws -> WalletAccount? {
        try await self.database.read { db in
            // 对齐 Kotlin getNonRootAccount：HD 子账户（isHD=1 && parentId 非空）或传统账户（isHD=0）
            try AccountRecord.fetchOne(
                db,
                sql: "SELECT * FROM accounts WHERE address = ? AND chain = ? AND ((isHD = 1 AND parentId IS NOT NULL) OR isHD = 0)",
                arguments: [address.normalizedAddress, chain.bip44Code]
            )?.account
        }
    }

    public func maxIndexByChain(parentId: String, chain: ChainType) async throws -> Int {
        try await self.database.read { db in
            let sql = """
            SELECT MAX(pathIndex) FROM accounts
            WHERE parentId = ? AND chain = ? AND pathIndex IS NOT NULL
            """
            guard let max = try Int.fetchOne(db, sql: sql, arguments: [parentId, chain.bip44Code]) else {
                return -1 // 空表：MAX 为 NULL（Kotlin ?: -1）
            }
            return max
        }
    }

    public func countSubAccountsByChain(parentId: String, chain: ChainType) async throws -> Int {
        try await self.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM accounts WHERE parentId = ? AND chain = ?",
                arguments: [parentId, chain.bip44Code]
            ) ?? 0
        }
    }

    public func currentAccountId() async throws -> String? {
        try await self.database.read { db in
            try CurrentAccountRecord.fetchOne(db)?.accountId
        }
    }

    public func sameAccountsCount(address: String) async throws -> Int {
        try await self.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM accounts WHERE address = ?",
                arguments: [address.normalizedAddress]
            ) ?? 0
        }
    }

    // MARK: - 观察流适配

    /// 观察流出错记日志（review SwiftAccount P1#8）：原静默 `finish()` 让消费方无法感知
    /// 流死亡（如表被删）；仍 finish（AsyncStream 无错误通道），但至少留痕可排查。
    private static let logger = Logger(subsystem: "com.jccdex.toolkits.swiftaccount", category: "GRDBAccountStore")

    private func stream<Value, Mapped>(
        _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
        map: @escaping @Sendable (Value) -> Mapped
    ) -> AsyncStream<Mapped> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: self.database) {
                        continuation.yield(map(value))
                    }
                    continuation.finish()
                } catch {
                    // P1#8：留痕（只打 domain#code，不打 payload——GRDB 错误可能含 SQL/绑定值）
                    if let nsError = error as NSError? {
                        Self.logger.error("observation ended with error: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                    } else {
                        Self.logger.error("observation ended with error: \(String(describing: error), privacy: .public)")
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 存储层错误（`setCurrentAccount` 账户不存在等）。
public enum AccountStoreError: Error, Equatable, Sendable {
    case accountNotFound(String)
}

// MARK: - 记录

/// accounts 表记录（id 文本主键；chain 存 BIP44 code）。
struct AccountRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    var id: String
    var address: String
    var chain: Int64
    var name: String
    var isHD: Bool
    var parentId: String?
    var pathAccount: Int?
    var pathChange: Int?
    var pathIndex: Int?
    var publicKey: String

    static let databaseTableName = "accounts"

    enum Columns {
        static let id = Column("id")
        static let address = Column("address")
        static let chain = Column("chain")
        static let name = Column("name")
        static let isHD = Column("isHD")
        static let parentId = Column("parentId")
        static let pathAccount = Column("pathAccount")
        static let pathChange = Column("pathChange")
        static let pathIndex = Column("pathIndex")
        static let publicKey = Column("publicKey")
    }

    /// 全参数 init（自定义 `init(account:)` 会隐藏 memberwise init，测试/转换需显式构造）。
    init(
        id: String,
        address: String,
        chain: Int64,
        name: String,
        isHD: Bool,
        parentId: String?,
        pathAccount: Int?,
        pathChange: Int?,
        pathIndex: Int?,
        publicKey: String
    ) {
        self.id = id
        self.address = address
        self.chain = chain
        self.name = name
        self.isHD = isHD
        self.parentId = parentId
        self.pathAccount = pathAccount
        self.pathChange = pathChange
        self.pathIndex = pathIndex
        self.publicKey = publicKey
    }

    init(account: WalletAccount) {
        self.id = account.id
        self.address = account.address.normalizedAddress // 写入归一（v2 起；查询不再 LOWER()，见 review C-1）
        self.chain = account.chain.bip44Code
        self.name = account.name
        self.isHD = account.isHD
        self.parentId = account.parentId
        self.pathAccount = account.path?.account
        self.pathChange = account.path?.change
        self.pathIndex = account.path?.index
        self.publicKey = account.publicKey
    }

    var account: WalletAccount {
        // path.chain 不落库：读回按账户 chain 列重建（对齐 Kotlin toWalletAccount）
        let path = self.pathIndex.map { Path(
            chain: self.chain,
            account: self.pathAccount ?? 0,
            change: self.pathChange ?? 0,
            index: $0
        ) }
        return WalletAccount(
            id: self.id,
            address: self.address,
            chain: ChainType.fromBip44Code(self.chain) ?? .eth, // 未知 code 回退 .eth（对齐 Kotlin）
            name: self.name,
            isHD: self.isHD,
            parentId: self.parentId,
            path: path,
            publicKey: self.publicKey
        )
    }
}

/// current_account 表记录（固定 id = 1 单行）。
struct CurrentAccountRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    var id: Int
    var accountId: String
    static let databaseTableName = "current_account"

    enum Columns {
        static let id = Column("id")
        static let accountId = Column("accountId")
    }
}
