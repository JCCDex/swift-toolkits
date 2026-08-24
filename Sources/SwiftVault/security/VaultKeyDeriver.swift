import Foundation

/// `Sendable`：deriver 实例被 `VaultRepository` actor 持有并在 detached 任务中跨隔离使用
/// （见 review SwiftVault P1#3）；实现为无状态 final class，安全。
public protocol VaultKeyDeriver: Sendable {
    func deriveKey(password: Data, salt: Data, parameters: PasswordKDFParameters) throws -> Data
}

public extension VaultKeyDeriver {
    /// 异步派生：默认实现把同步 KDF（64–256 MiB 内存）挪到 detached 任务——
    /// 调用方（`VaultRepository` actor）`await` 期间不阻塞 actor 上的其他操作
    /// （见 review SwiftVault P1#3；自定义 deriver 可覆盖以提供原生 async 实现）。
    func deriveKeyAsync(password: Data, salt: Data, parameters: PasswordKDFParameters) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try self.deriveKey(password: password, salt: salt, parameters: parameters)
        }.value
    }
}
