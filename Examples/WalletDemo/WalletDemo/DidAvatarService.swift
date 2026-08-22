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

/// DID 头像服务：组合 SwiftDid（链上解析 + 头像 VC）与 SwiftNft（元数据/图片解析）。
///
/// 解析链**全部走 SwiftDid SDK 公开 API，demo 零解析逻辑**：
/// `resolveDid`（本地已有文档则跳过，避免 loading 等待）→ `generateProfileVC`（读
/// preferredAvatar VC，SDK 内部经 SwiftNft 解析出图片 URL 并落 `nft_meta` 缓存）。
///
/// 缓存全部走本地 sqlite，**不依赖 UserDefaults**：
/// - DID 文档落 `did.sqlite`（did_documents），解析成功后图片 URL 落 `nft.sqlite`
///   （`nft_meta.image`，SDK 的 `resolveSwtcAvatar`/`resolveEthrAvatar` 本地命中即返回）；
/// - 重启后**头像图片已落盘（`avatars/<did>.img`）的直接出图，不显示 loading、跳过解析**；
///   未落盘的并行解析：文档/元数据已缓存 → SDK 内部本地直接出图；未缓存的走链上解析，
///   且**各 DID 并行**。
@MainActor
final class DidAvatarService: ObservableObject {
    @Published var items: [DidAvatarItem] = SampleDid.list.map { DidAvatarItem(did: $0) }
    @Published var started = false

    private var sdk: SwiftDid?
    private let log = Logger(subsystem: "com.swifttoolkits.WalletDemo", category: "did-avatar")

    func start() async {
        guard !self.started else { return }
        self.started = true
        do {
            let (didDB, nftDB) = try Self.makeStores()
            let nftStore = try GRDBNftStore(database: nftDB)
            // SwiftNft：元数据/图片解析（EVM tokenURI 由模块内 EthTokenUriResolver（eth_call）
            // 提供；RPC URL 由宿主经 getRpcNode 闭包按 chainId 注入，模块不内置端点）
            let nft = NftClient(config: SwiftNftConfig(
                store: nftStore,
                httpClient: URLSessionNftHttpClient(),
                ethTokenUriResolver: EthTokenUriResolver(getRpcNode: { chainId in
                    switch chainId {
                    case 1: "https://ethereum-rpc.publicnode.com"
                    case 56: "https://bsc-dataseed.binance.org"
                    case 137: "https://polygon-rpc.com"
                    case 8453: "https://mainnet.base.org"
                    case 42161: "https://arb1.arbitrum.io/rpc"
                    default: nil
                    }
                }),
                swtcTokenUriResolver: SwtcTokenUriResolver(getRpcNode: { "https://srje115qd43qw2.swtc.top" })
            ))
            // SwiftDid：自持 did-bridge WebView（默认 EngineDidBridge）+ GRDB 存储 + SwiftNft 接入
            let sdk = try SwiftDid(store: GRDBDidStore(database: didDB), nft: nft)
            try sdk.start()
            self.sdk = sdk

            // 1) 本地图片文件预检：上次解析成功已落盘 `avatars/<did>.img` 的头像
            //    直接出图（localImagePath）、不显示 loading，并跳过网络/链上解析。
            await withTaskGroup(of: Void.self) { group in
                for index in self.items.indices where self.items[index].imageURL == nil {
                    group.addTask { await self.preloadLocalImage(index: index) }
                }
            }

            // 2) 并行解析缺失头像（各 DID 独立、互不阻塞）：未落盘的才走 SDK——
            //    已缓存（文档 + nft_meta）的由 SDK 内部本地直接出图；未缓存的走链上解析，
            //    期间显示 loading。
            await withTaskGroup(of: Void.self) { group in
                for index in self.items.indices
                    where self.items[index].imageURL == nil && self.items[index].localImagePath == nil {
                    group.addTask { await self.loadAvatar(index: index) }
                }
            }
        } catch {
            self.log.error("DID avatar service start failed: \(error.localizedDescription)")
            self.failAll(error.localizedDescription)
        }
    }

    /// 本地图片文件预检（纯文件系统检查，无解析）：`avatars/<did>.img` 已存在 →
    /// 直接出图、不转圈。
    private func preloadLocalImage(index: Int) async {
        guard let path = Self.localImageURL(for: self.items[index].did),
              FileManager.default.fileExists(atPath: path.path)
        else { return }
        self.items[index].localImagePath = path.path
        self.items[index].isLoading = false
    }

    private func loadAvatar(index: Int) async {
        let did = self.items[index].did
        guard let sdk else { return }

        // 本地已缓存 DID 文档 → 跳过链上解析、不显示 loading（SDK getDidDocument 纯本地）
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

        // 头像 NFT 由 SDK generateProfileVC 解析（preferredAvatar VC → SwiftNft 元数据/图片，缓存优先）
        guard let profileVC = await sdk.generateProfileVC(did),
              let image = profileVC.nft?.image, !image.isEmpty,
              let url = URL(string: image)
        else {
            self.fail(index, "头像 NFT 元数据不可解析")
            return
        }
        self.succeed(index, url)
    }

    private func succeed(_ index: Int, _ url: URL) {
        self.items[index].isLoading = false
        self.items[index].imageURL = url
        self.items[index].errorText = nil
        // 图片 URL 已由 SDK（SwiftNft fetchAndCacheNftMeta）落 `nft_meta`（sqlite），无需 UserDefaults；
        // 仅把图片文件落本地磁盘，下次直接从文件出图。
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
