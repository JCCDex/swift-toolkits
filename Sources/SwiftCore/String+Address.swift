import Foundation

// MARK: - 地址归一化 / 大小写不敏感比较

/// 归口此前分散的实现（见 review 四、架构层观察 #2）：
/// - `VaultRepository.normalizedAddress`（lowercased，AAD 绑定用）
/// - `VaultModels.AddressableRecord.matches`（caseInsensitiveCompare）
/// - `EthMiddleware` 三处 `caseInsensitiveCompare(...) == .orderedSame`
/// - GRDB `LOWER(address)`（SQL 侧，见存储/索引项 C-1，不受本扩展影响）
public extension String {
    /// 地址归一化基准：小写化（EIP-55 混合大小写地址比较用；不做 checksum）。
    var normalizedAddress: String {
        lowercased()
    }

    /// 大小写不敏感地址相等（替代 `caseInsensitiveCompare(...) == .orderedSame`）。
    func addressEquals(_ other: String) -> Bool {
        self.normalizedAddress == other.normalizedAddress
    }
}
