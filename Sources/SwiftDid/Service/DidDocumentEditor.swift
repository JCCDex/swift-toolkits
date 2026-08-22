import Foundation

/// DID 文档读改写纯函数（无 I/O）：抽取门面里 services/credentials 的重构逻辑，
/// 使各写操作只提供差异化 transform（见 review 优化 #13）。
enum DidDocumentEditor {

    // MARK: - services

    /// 读 service（`service` / `services` 双键别名）。
    static func services(from json: [String: Any]) -> [Any] {
        DidJson.optArray(json, "service") ?? DidJson.optArray(json, "services") ?? []
    }

    /// 写 `service` 前删除旧 `services` 键（Swift 修正：Kotlin 会双键漂移，见 Did-Swift 01 §6 缺陷 #4）。
    static func setServices(_ services: [Any], on json: inout [String: Any]) {
        json.removeValue(forKey: "services")
        json["service"] = services
    }

    /// 重建 Profile service（对齐 Kotlin 写入形态：只保留 id/type/serviceEndpoint 三键）。
    static func profileService(did: String, nickname: String, preferredAvatar: String) -> [String: Any] {
        [
            "id": "\(did)#profile",
            "type": "Profile",
            "serviceEndpoint": ["nickname": nickname, "preferredAvatar": preferredAvatar]
        ]
    }

    /// 重建 IpfsStorage service：保留原 id 与 serviceEndpoint 键，仅 previousCid 非空时写入（镜像 `applyPreviousCid`）。
    static func ipfsStorageService(did: String, from service: [String: Any], previousCid: String?) -> [String: Any] {
        var endpoint = DidJson.optDict(service, "serviceEndpoint") ?? [:]
        if let previousCid, !previousCid.isEmpty {
            endpoint["previousCid"] = previousCid
        }
        return [
            "id": DidJson.optString(service, "id", default: "\(did)#ipfs-storage"),
            "type": "IpfsStorage",
            "serviceEndpoint": endpoint
        ]
    }

    // MARK: - credentials

    /// 读 credentials（`credentials` / `credential` 双键别名，与 `DidCredentialHelper` 共用同一实现）。
    static func credentials(from json: [String: Any]) -> [Any] {
        DidCredentialHelper.credentials(in: json)
    }

    /// 若为 IpfsStorage service 则重建并注入 `previousCid`，否则原样返回。
    /// 门面三处（updateDidNickname / updateDidAvatar / applyPreviousCid）共用同一「类型判断 +
    /// 重建」变换（见跨模块重复 2.2）。
    static func serviceWithPreviousCid(did: String, service: [String: Any], previousCid: String?) -> Any {
        guard DidJson.optString(service, "type") == "IpfsStorage" else { return service }
        return self.ipfsStorageService(did: did, from: service, previousCid: previousCid)
    }

    /// upsert：按 id 替换（case-insensitive），未命中追加。
    static func upsertCredential(_ credentials: [Any], incoming: [String: Any], byId id: String) -> [Any] {
        var updated: [Any] = []
        var replaced = false
        for element in credentials {
            if let existing = element as? [String: Any],
               DidJson.optString(existing, "id").caseInsensitiveCompare(id) == .orderedSame {
                updated.append(incoming)
                replaced = true
            } else {
                updated.append(element)
            }
        }
        if !replaced {
            updated.append(incoming)
        }
        return updated
    }

    /// 按 id 删除（case-insensitive）；未命中返回 nil。
    static func removingCredential(_ credentials: [Any], byId id: String) -> [Any]? {
        let index = DidCredentialHelper.findCredentialIndex(credentials, id)
        guard index >= 0 else { return nil }
        return credentials.enumerated().compactMap { $0.offset == index ? nil : $0.element }
    }
}
