import Foundation
import GRDB
import os
import SwiftDid
import SwiftNft

/// DID 头像展示项（loading / 图片 URL / 本地图片文件 / 错误）。
struct DidAvatarItem: Identifiable {
    let did: String
    var isLoading = true
    var imageURL: URL?
    var localImagePath: String? // 头像图片已落本地磁盘 → 直接出图、不走网络/不转圈
    var errorText: String?

    var id: String {
        self.did
    }
}

/// 示例 DID（SWTC 与 ETH 各一个）。
enum SampleDid {
    static let list = [
        "did:swtc:jwWmuiN6B1KjNJjH6f8cFxeY83UpjSMRWq",
        "did:ethr:0xa4FdA51E902Ba5f6b6322DEe039be7678Ba4584F"
    ]
}

/// DID 头像服务：组合 SwiftDid（链上解析 + Profile/头像 VC）与 SwiftNft（元数据/图片解析）。
///
/// 解析链：`resolveDid`（本地已有文档则跳过，避免 loading 等待）→ `generateProfileVC`
/// （读 preferredAvatar VC）→ nft.image；preferredAvatar 的 NFT 元数据不可解析时（如
/// tokenURI 链上 revert）兜底用 DID 自有的 SWTC ownership VC（`generateSwtcNft` → erc_info）。
/// 已解析的图片 URL 持久化到 UserDefaults，重启后「已加载过」的 DID 直接出图、不显示 loading。
@MainActor
final class DidAvatarService: ObservableObject {
    @Published var items: [DidAvatarItem] = SampleDid.list.map { DidAvatarItem(did: $0) }
    @Published var started = false

    private var sdk: SwiftDid?
    private let log = Logger(subsystem: "com.swifttoolkits.WalletDemo", category: "did-avatar")

    private static let urlCacheKeyPrefix = "didAvatar.imageURL."

    init() {
        // 重启恢复：已解析过的 DID 直接带图片 URL；图片文件已落磁盘的连下载都省了，
        // 直接出本地图（AsyncImage 网络下载的转圈也不出现）。
        for index in self.items.indices {
            let did = self.items[index].did
            let key = Self.urlCacheKeyPrefix + did
            guard let saved = UserDefaults.standard.string(forKey: key), let url = URL(string: saved) else { continue }
            self.items[index].imageURL = url
            self.items[index].isLoading = false
            if let path = Self.localImageURL(for: did), FileManager.default.fileExists(atPath: path.path) {
                self.items[index].localImagePath = path.path
            } else {
                // URL 已落库但图片文件缺失（旧版本数据/首次升级）：后台补落盘，
                // 本次 AsyncImage 下载的同时写文件，下次进页面直接出本地图。
                self.cacheImageFile(url: url, did: did)
            }
        }
    }

    func start() async {
        guard !self.started else { return }
        self.started = true
        do {
            let (didDB, nftDB) = try Self.makeStores()
            // SwiftNft：元数据/图片解析（EVM tokenURI 由模块内 EthTokenUriResolver（eth_call）
            // 提供；RPC URL 由宿主经 rpcUrlsForChain 闭包按 chainId 注入，模块不内置端点）
            let nft = try SwiftNft(config: SwiftNftConfig(
                store: GRDBNftStore(database: nftDB),
                httpClient: URLSessionNftHttpClient(),
                ethTokenUriResolver: EthTokenUriResolver(rpcUrlsForChain: { chainId in
                    switch chainId {
                    case 1: "https://ethereum-rpc.publicnode.com"
                    case 56: "https://bsc-dataseed.binance.org"
                    case 137: "https://polygon-rpc.com"
                    case 8453: "https://mainnet.base.org"
                    case 42161: "https://arb1.arbitrum.io/rpc"
                    default: nil
                    }
                }),
                swtcChainNftClient: SwtcNftClient(getRpcNode: { "https://srje115qd43qw2.swtc.top" })
            ))
            // SwiftDid：自持 did-bridge WebView（默认 EngineDidBridge）+ GRDB 存储 + SwiftNft 接入
            let sdk = try SwiftDid(store: GRDBDidStore(database: didDB), nft: nft)
            try sdk.start()
            self.sdk = sdk

            // 本地缓存预检：DID 文档已落 sqlite 的 item 立即停转圈（GRDB 本地查询毫秒级）。
            // 否则下方顺序 await 时，未缓存 DID 的链上解析（可能数秒）会拖住已缓存 DID 的
            // loading——后者要等前者完成才轮到 loadAvatar，期间一直显示「解析中」。
            for index in self.items.indices where self.items[index].imageURL == nil {
                if await (try? sdk.getDidDocument(self.items[index].did)) != nil {
                    self.items[index].isLoading = false
                }
            }
            for index in self.items.indices {
                if self.items[index].imageURL == nil {
                    await self.loadAvatar(index: index)
                }
            }
        } catch {
            self.log.error("DID avatar service start failed: \(error.localizedDescription)")
            self.failAll(error.localizedDescription)
        }
    }

    private func loadAvatar(index: Int) async {
        let did = self.items[index].did
        guard let sdk else { return }

        // 本地已缓存 DID 文档 → 跳过链上解析、不显示 loading（start() 预检已停转圈，此处幂等）
        let cached = await (try? sdk.getDidDocument(did)) != nil
        if !cached {
            switch await sdk.resolveDid(did) {
            case .document:
                break
            case .missing:
                self.fail(index, "链上不存在")
                return
            case let .error(error):
                self.fail(index, "解析失败：\(error.localizedDescription)")
                return
            }
        } else {
            self.items[index].isLoading = false // 已缓存：不再转圈
        }

        guard let profileVC = await sdk.generateProfileVC(did) else {
            self.fail(index, "无 Profile")
            return
        }
        if let image = profileVC.nft?.image, let url = URL(string: image) {
            self.succeed(index, url)
            return
        }

        // 兜底：preferredAvatar 的 NFT 元数据不可解析（如 tokenURI 链上 revert）
        // → 用 DID 自有的 SWTC ownership VC（erc_info → 元数据 → 图片）
        if let entity = try? await sdk.getDidDocument(did),
           let vc = Self.swtcOwnershipVC(in: entity.doc) {
            let nft = await sdk.generateSwtcNft(vc)
            if let image = nft?.image, let url = URL(string: image) {
                self.succeed(index, url)
                return
            }
        }
        self.fail(index, "头像 NFT 元数据不可解析")
    }

    private func succeed(_ index: Int, _ url: URL) {
        self.items[index].isLoading = false
        self.items[index].imageURL = url
        self.items[index].errorText = nil
        UserDefaults.standard.set(url.absoluteString, forKey: Self.urlCacheKeyPrefix + self.items[index].did)
        self.cacheImageFile(url: url, did: self.items[index].did)
    }

    /// 头像图片落本地磁盘（`Application Support/WalletDemo/avatars/`）：
    /// 下载成功写文件并回填 `localImagePath`，之后进页面直接从文件出图，不显示 loading。
    /// 下载失败（网络抖动等）不阻塞出图——本页仍走 AsyncImage，下次解析再补缓存。
    private func cacheImageFile(url: URL, did: String) {
        Task {
            guard let target = Self.localImageURL(for: did) else { return }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode)
            else { return }
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard (try? data.write(to: target, options: .atomic)) != nil else { return }
            if let index = self.items.firstIndex(where: { $0.did == did }) {
                self.items[index].localImagePath = target.path
            }
        }
    }

    /// 头像图片本地文件 URL：按 did 文件名隔离（同一 DID 换头像覆盖旧文件）。
    private static func localImageURL(for did: String) -> URL? {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("WalletDemo/avatars", isDirectory: true)
        let name = did.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "avatar"
        return dir.appendingPathComponent(name + ".img")
    }

    private func fail(_ index: Int, _ message: String) {
        self.items[index].isLoading = false
        self.items[index].errorText = message
    }

    private func failAll(_ message: String) {
        for index in self.items.indices {
            self.fail(index, message)
        }
    }

    /// 在文档 credentials 里找 DID 自有的 SWTC ownership VC：
    /// type 含 `NFTOwnership`、subject.standard == `jingtumNFT`、subject.owner == 文档 id。
    private static func swtcOwnershipVC(in doc: String) -> String? {
        guard let data = doc.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let docID = root["id"] as? String,
              let credentials = root["credentials"] as? [Any]
        else { return nil }
        for element in credentials {
            guard let vc = element as? [String: Any],
                  let types = vc["type"] as? [Any],
                  types.contains(where: { ($0 as? String)?.caseInsensitiveCompare("NFTOwnership") == .orderedSame }),
                  let subject = vc["credentialSubject"] as? [String: Any],
                  let standard = subject["standard"] as? String,
                  standard.caseInsensitiveCompare("jingtumNFT") == .orderedSame,
                  let owner = subject["owner"] as? String, owner == docID
            else { continue }
            guard let vcData = try? JSONSerialization.data(withJSONObject: vc) else { continue }
            return String(data: vcData, encoding: .utf8)
        }
        return nil
    }

    private static func makeStores() throws -> (DatabasePool, DatabasePool) {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("WalletDemo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (
            DatabasePool(path: dir.appendingPathComponent("did.sqlite").path),
            DatabasePool(path: dir.appendingPathComponent("nft.sqlite").path)
        )
    }
}
