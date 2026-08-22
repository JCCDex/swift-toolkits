import Foundation
import SwiftCore

/// 包装 `SecretProvider`，按 `origin|address` 缓存私钥/秘钥：
/// - 批次内复用：最后一次操作结束后 5s 内不再委托（不重复弹密码）
/// - 绝对上限 20s：超过强制重新认证
/// - `clearCache()`：切后台 / 锁屏 / 切换账户时调用
/// - 私钥与秘钥分别做 in-flight 去重，同地址并发只委托一次
public actor CachingSecretProvider: SecretProvider {
    private struct Entry {
        let value: String
        let at: UInt64 // epoch milliseconds
    }

    private let delegate: any SecretProvider
    private let bridgeWindowMs: UInt64
    private let maxAgeMs: UInt64

    private var cache: [String: Entry] = [:]
    private var inFlightPrivate: [String: Task<String?, Error>] = [:]
    private var inFlightSecret: [String: Task<String?, Error>] = [:]
    private var activeOps = 0
    private var clearTask: Task<Void, Never>?

    public init(
        delegate: any SecretProvider,
        bridgeWindowMs: UInt64 = 5000,
        maxAgeMs: UInt64 = 20000
    ) {
        self.delegate = delegate
        self.bridgeWindowMs = bridgeWindowMs
        self.maxAgeMs = maxAgeMs
    }

    public func getPrivateKeyForAddress(_ address: String, origin: String) async throws -> String? {
        try await self.fetch(cacheKey: "pk:\(origin)|\(address)", address: address, origin: origin, isSecret: false)
    }

    public func getSecretForAddress(_ address: String, origin: String) async throws -> String? {
        try await self.fetch(cacheKey: "sec:\(origin)|\(address)", address: address, origin: origin, isSecret: true)
    }

    /// 强制清空缓存（切后台 / 锁屏 / 切换账户时调用）。
    public func clearCache() {
        self.cache.removeAll()
        self.clearTask?.cancel()
        self.clearTask = nil
    }

    // MARK: - 内部

    private func fetch(cacheKey: String, address: String, origin: String, isSecret: Bool) async throws -> String? {
        if let entry = cache[cacheKey] {
            if self.nowMs() - entry.at < self.maxAgeMs {
                return entry.value
            }
            self.cache.removeValue(forKey: cacheKey)
        }

        // in-flight 去重：并发请求共用同一个委托任务，避免重复弹密码。
        let existing = isSecret ? self.inFlightSecret[cacheKey] : self.inFlightPrivate[cacheKey]
        if let existing {
            return try await existing.value
        }

        let task = Task { [delegate] in
            if isSecret {
                return try await delegate.getSecretForAddress(address, origin: origin)
            }
            return try await delegate.getPrivateKeyForAddress(address, origin: origin)
        }
        if isSecret {
            self.inFlightSecret[cacheKey] = task
        } else {
            self.inFlightPrivate[cacheKey] = task
        }

        self.beginOp()
        defer { endOp() }

        do {
            let value = try await task.value
            if isSecret {
                self.inFlightSecret[cacheKey] = nil
            } else {
                self.inFlightPrivate[cacheKey] = nil
            }
            if let value {
                self.cache[cacheKey] = Entry(value: value, at: self.nowMs())
            }
            return value
        } catch {
            if isSecret {
                self.inFlightSecret[cacheKey] = nil
            } else {
                self.inFlightPrivate[cacheKey] = nil
            }
            throw error
        }
    }

    private func beginOp() {
        self.activeOps += 1
        self.clearTask?.cancel()
        self.clearTask = nil
    }

    private func endOp() {
        self.activeOps = max(self.activeOps - 1, 0)
        if self.activeOps == 0 {
            self.clearTask?.cancel()
            let bridgeWindowMs = bridgeWindowMs
            self.clearTask = Task { [weak self] in
                // 被取消（新操作已开始 / clearCache 触发）时直接返回，绝不能继续清缓存。
                do {
                    try await Task.sleep(nanoseconds: bridgeWindowMs * 1_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.clearCache()
            }
        }
    }

    private func nowMs() -> UInt64 {
        UInt64(Date.nowMillis())
    }
}
