import Foundation
import SwiftNft

// MARK: - DID 文档 / Profile 展示模型（镜像 Kotlin :did model/DidModels.kt，commit f77b59f）

public struct GenerateBase58PKResult: Codable, Sendable, Equatable {
    public let type: String
    public let publicKeyBase58: String

    public init(type: String, publicKeyBase58: String) {
        self.type = type
        self.publicKeyBase58 = publicKeyBase58
    }
}

public struct PublishDidResult: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct DidStatResult: Codable, Sendable, Equatable {
    public let cid: String?

    public init(cid: String?) {
        self.cid = cid
    }
}

public struct VerificationMethod: Codable, Sendable, Equatable {
    public let id: String
    public let controller: String
    public let type: String
    public let publicKeyBase58: String
    public let isSelf: Bool

    public init(id: String, controller: String, type: String, publicKeyBase58: String, isSelf: Bool) {
        self.id = id
        self.controller = controller
        self.type = type
        self.publicKeyBase58 = publicKeyBase58
        self.isSelf = isSelf
    }
}

public struct Did: Codable, Sendable, Equatable {
    public let id: String
    public let created: String
    public let updated: String
    public let verificationMethods: [VerificationMethod]

    public init(id: String, created: String, updated: String, verificationMethods: [VerificationMethod]) {
        self.id = id
        self.created = created
        self.updated = updated
        self.verificationMethods = verificationMethods
    }
}

public struct Profile: Codable, Sendable, Equatable {
    public let nickname: String
    public let preferredAvatar: String

    public init(nickname: String, preferredAvatar: String) {
        self.nickname = nickname
        self.preferredAvatar = preferredAvatar
    }
}

/// Profile + 头像 NFT 展示模型（`nft` 为 SwiftNft.Nft 的 typealias）。
public struct ProfileVC: Codable, Sendable, Equatable {
    public let nickname: String
    public let bio: String
    public let createdTime: String
    public let nft: Nft?

    public init(nickname: String, bio: String, createdTime: String, nft: Nft?) {
        self.nickname = nickname
        self.bio = bio
        self.createdTime = createdTime
        self.nft = nft
    }
}

/// 本地 DID 文档实体（对外**不暴露自增 id**——id 主键保留在 GRDB 记录层，对齐 Kotlin
/// `DidEntity{id, did, doc, updatedAt}` 但 id 不公开，见 Did-Swift 02 §4）。
public struct DidEntity: Codable, Sendable, Equatable {
    public let did: String
    public let doc: String
    public let updatedAt: Int64 // 毫秒时间戳

    public init(did: String, doc: String, updatedAt: Int64) {
        self.did = did
        self.doc = doc
        self.updatedAt = updatedAt
    }
}

/// pending 对账记录（对应 Kotlin DidCoreService 的四张 ConcurrentHashMap；Swift 持久化到
/// `did_pending` 表消除重启窗口，见 Did-Swift 01 §6 / 02 §4）。
public struct DidPending: Codable, Sendable, Equatable {
    public let kind: String // create / avatar / nickname / delete
    public let did: String
    public let value: String? // kind 相关负载（avatar→preferredAvatar、nickname→nickname、delete→updated 时间戳）
    public let updatedAt: Int64 // 写入时间（毫秒），TTL 以首次写入为基准、不续期

    public init(kind: String, did: String, value: String?, updatedAt: Int64) {
        self.kind = kind
        self.did = did
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// 头像凭证（镜像 Kotlin `DidAvatarCredential`）。
public struct DidAvatarCredential: Codable, Sendable, Equatable {
    public let credentialId: String
    public let image: String?
    public let name: String
    public let contract: String?
    public let tokenId: String
    public let issuer: String?
    public let tokenName: String?
    public let chainId: Int64?
    public let isSwtc: Bool
    public let ownerDid: String

    public init(
        credentialId: String,
        image: String?,
        name: String,
        contract: String?,
        tokenId: String,
        issuer: String?,
        tokenName: String?,
        chainId: Int64?,
        isSwtc: Bool,
        ownerDid: String
    ) {
        self.credentialId = credentialId
        self.image = image
        self.name = name
        self.contract = contract
        self.tokenId = tokenId
        self.issuer = issuer
        self.tokenName = tokenName
        self.chainId = chainId
        self.isSwtc = isSwtc
        self.ownerDid = ownerDid
    }
}

public struct DidWriteResult: Codable, Sendable, Equatable {
    public let success: Bool
    public let didDocument: String?

    public init(success: Bool, didDocument: String? = nil) {
        self.success = success
        self.didDocument = didDocument
    }
}

/// 多 DID 批量同步模型（镜像 Kotlin；`DidSyncService` 一期裁剪、二期补——模型保留）。
public struct DidSyncEntry: Codable, Sendable, Equatable {
    public let did: String
    public let addressLower: String
    public let document: String
    public let nickname: String

    public init(did: String, addressLower: String, document: String, nickname: String) {
        self.did = did
        self.addressLower = addressLower
        self.document = document
        self.nickname = nickname
    }
}

public struct DidSyncResult: Codable, Sendable, Equatable {
    public let entries: [DidSyncEntry]

    public init(entries: [DidSyncEntry]) {
        self.entries = entries
    }

    public var addressesLower: Set<String> {
        Set(self.entries.map(\.addressLower))
    }
}

/// 链上解析三态结果（Swift 增强，见 Did-Swift 04 坑 #15）：
/// 桥/网络错误用独立 error 分支，不得伪装成 missing。
/// 约定：`resolveDid` / `resolveAndSaveDid` **不 throw**——所有失败统一进 `.error(any Error)`，
/// 由调用方按三态 switch 决策；throw 通道留给编程错误（参数非法等）。
public enum DidResolveOutcome {
    case missing
    case error(any Error)
    case document(String)
}

public enum SwiftDidError: Error, Equatable {
    case notInitialized
    case invalidPayload
    case invalidCredential
    case didNotFound
}
