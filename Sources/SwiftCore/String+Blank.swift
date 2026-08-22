import Foundation

// MARK: - 空白判断 / 空串归一（归口 SwiftDid 与 SwiftNft 各 2-3 份重复实现，见 review 跨模块重复 2.1）

public extension String {
    /// trim 后是否为空。
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 空白 → nil，否则原样（缺失文档 / 空字段归一用）。
    var nilIfBlank: String? {
        self.isBlank ? nil : self
    }
}

/// `String?` 空白判断（SwiftNft 现有调用点 `isBlank(x)` 兼容签名）。
public func isBlank(_ value: String?) -> Bool {
    value?.isBlank ?? true
}
