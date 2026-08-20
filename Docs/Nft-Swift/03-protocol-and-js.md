# 03 · 协议与 JS

> 对齐依据：`kotlin-toolkits` commit `f77b59f`（`nft/src/main/java/com/jccdex/toolkits/nft/remote/`）。

## 1. 传输：无 JS 桥（与 did-bridge.js 的分工）

**SwiftNft 不新增、不调用任何 JS**：元数据/图片拉取、EVM `eth_call`、SWTC `erc_info` RPC 均为纯原生网络（`NftHttpClient`：fetchJson/fetchText 不跟随重定向，fetchRpc 跟随重定向），与 SwiftDid/SwiftWallet 的隐藏 WebView 桥（`did-bridge.html` / `wallet-bridge.html`）无关。

与 `did-bridge.js` 的关系（跨模块）：

- **VC 签发**：DID 头像/NFT 凭证（VC）由 `did-bridge.js` 的 `issueVC` 签发（`@context` 走内联 NFT 术语集 `nftContextFor(brand, contextType)`，如 `CCDAO_NFT_OWNERSHIP_CONTEXT` / `JDID_NFT_USAGE_AUTHORIZATION_CONTEXT`，见 `SwiftWebviewBridge/Resources/bridge/did-bridge.js`）。
- **VC 消费**：SwiftNft 只**消费** VC 里携带的字段（`resolveSwtcAvatar`/`resolveEthrAvatar` 读 `credentialSubject.tokenId` / `nftIssuer` / `contractAddress` / `chainId` / `tokenName` + `issuanceDate`），**不参与签发**；元数据 URI 本体来自链上 `erc_info` 或本地 `swtc_nfts.metadataUri`（SWTC）、宿主 `IEthTokenUriResolver`（EVM），不经 JS。

## 2. ERC-721（EVM）元数据协议

### 2.1 tokenURI

- `IEthTokenUriResolver` 是可注入接口（`resolveEthrTokenUri(contract, tokenId, chainId): String?`，非 throw，失败返回 nil）；SwiftNft 同时**随包提供默认实现** `EthTokenUriResolver`（eth_call：ERC-721 `tokenURI(uint256)` selector `0xc87b56dd`，calldata 只拼 32 字节十进制 tokenId、合约地址走 `to` 字段，ABI string 解码假定 offset=32，URI 过 `normalizeRemoteAssetUrl`）——**RPC 端点不内置**，由 `init(rpcUrlsForChain:)` 注入「chainId → RPC URL」函数（对齐 Kotlin app 侧 `defaultRpcUrlsForChain` / `AppEndpoints.RPC_*` 语义，见 02 §4.2）。
- 返回的元数据 URI 常见形式 `https://.../*.json` / `ipfs://<CID>` / `data:application/json;base64,...`（后两者由 SwiftNft 的 `normalizeRemoteAssetUrl` / `isLoadableRemoteAssetUrl` 处理）。

### 2.2 元数据 JSON（源码实况）

```json
{
  "name": "My NFT #123",
  "description": "…",
  "image": "ipfs://Qm…/image.png",
  "image_url": "…",
  "imageUrl": "…",
  "data": { "name": "…", "image": "./images/avatar.png" }
}
```

解析行为（`extractMetadataImageUrl` / `extractMetadataFields`，源码实况）：

| 规则 | 行为 |
| --- | --- |
| 顶层 JSON 对象 | `JSONObject` 容错解析，失败返回 nil/空结构（不 throw） |
| `data` 键解包 | `optJSONObject("data") ?: root`——存在 `data` 对象时以其为载荷（Kotlin 测试锁定） |
| 图片键顺序 | `"image"` → `"image_url"` → `"imageUrl"`，取首个**非空且可规范化**的值 |
| `name` / `description` | `optString().takeIf { isNotBlank }`；缺失 → nil |
| 图片规范化 | 命中后过 `normalizeRemoteAssetUrl(image, metadataUri)`（相对路径按元数据 URL join、`ipfs://` 重写） |

## 3. SWTC NFT 元数据（erc_info RPC，源码实况）

### 3.1 链上查询

```jsonc
// POST https://srje115qd43qw2.swtc.top（经 SwiftNftConfig.swtcTokenUriResolver 注入，节点由 `SwtcTokenUriResolver(getRpcNode:)` 提供；节点可信、跟随重定向，无 delegate）
{
  "method": "erc_info",
  "params": [ { "tokenid": "<tokenId>" } ]
}
// 响应（简化）：
{ "result": { "TokenInfo": { "TokenInfos": [ { "TokenInfo": { "InfoType": "746f6b656e557269", "InfoData": "697066733a2f2f…" } } ] } } }
```

- `TokenInfos` 可为 JSONArray 或字符串（源码两种都处理）。
- **`extractSwtcMetadataUri(tokenInfosPayload)`**：遍历数组，hex 解码 `InfoType` 须为 `"tokenUri"`（`"746f6b656e557269"`），再 hex 解码 `InfoData` 并经 `normalizeRemoteAssetUrl` 规范化，返回首个命中。
- KAT 用例（Kotlin 测试锁定）：`InfoData = "697066733a2f2f626166792d746573742f6d6574612e6a736f6e"` → 解码 `"ipfs://bafy-test/meta.json"` → 规范化 `"https://ipfs.jccdex.cn/ipfs/bafy-test/meta.json"`。

### 3.2 与 SWTC 转账的关系

`wallet-bridge.js` 的 `serialize721Payment(address, to, tokenId, fee, memo)` 构造 NFT 转账交易（`fundCode`/`issuer`/`tokenId` 语义由 jingtum-lib 定义，见 `SwiftWallet.buildSwtcNftTransfer`）——那是**转账**面，属 SwiftWallet/SwtcMiddleware（M-18）；SwiftNft 只管**元数据**面（`erc_info`）。SWTC 链上**持仓枚举**同样不在 SwiftNft 的 DApp 面（宿主 `NftProvider.getSwtcNfts`，见 README 边界）。

## 4. IPFS 网关协议

### 4.1 重写规则（对齐 Kotlin `normalizeRemoteAssetUrl` ipfs 分支）

| 输入 | 结果（gateway = `https://ipfs.jccdex.cn/ipfs/`） | 说明 |
| --- | --- | --- |
| `ipfs://<CID>/path` | `https://ipfs.jccdex.cn/ipfs/<CID>/path` | `substringAfter("ipfs://")` 后剥 `ipfs/` 冗余前缀 |
| `/ipfs/<CID>/path` | `https://ipfs.jccdex.cn/ipfs/<CID>/path` | 剥开头的 `/` 与 `ipfs/` |
| `ipfs/<CID>/path` | `https://ipfs.jccdex.cn/ipfs/<CID>/path` | 同上 |
| `https://…/ipfs/<CID>/path` | `https://ipfs.jccdex.cn/ipfs/<CID>/path` | `canonicalizeHttpIpfsUrl`：路径含 `/ipfs/` 即换到默认网关 |
| `Qm…` / `bafy…`（裸 CID） | `https://ipfs.jccdex.cn/ipfs/<CID>` | `looksLikeIpfsIdentifier`（Qm/bafy 前缀） |
| 其他 http/https | 原样 | 仅规范化（trim） |

### 4.2 网关配置（Swift 增强）

- Kotlin **硬编码** `DEFAULT_IPFS_GATEWAY_BASE_URL = "https://ipfs.jccdex.cn/ipfs/"`（`NftRemoteAssetResolver.kt`）——与 `security-review.md` D5（did-bridge.js 硬编码网关）同类问题。
- Swift：`SwiftNftConfig.ipfsGateway` 可注入，**默认值保持与 Kotlin 相同**（行为对齐）；宿主可换网关/从远端下发。网关值本身做 URL 校验（http/https）。

> ⚠️ `canonicalizeHttpIpfsUrl` 会把**任意** http(s) URL 路径中含 `/ipfs/` 的地址强制换到（可配置的）
> 默认网关——网关可注入后这可能误伤第三方 URL（如 `https://cdn.thirdparty.com/ipfs/xyz` 被改写）。
> 二选一并在实现时固化：保持 Kotlin 行为（对齐优先），或把重写限定到已知 IPFS 网关域名
> （ipfs.io / cloudflare-ipfs.com / jccdex 等），见 04 坑 #9。

## 5. 资产 URL 规范化（normalizeRemoteAssetUrl 规则，源码实况）

纯函数规则表（`Util/NftUrlUtils.swift`；Swift 落地后用 Kotlin 测试向量做 KAT 对齐）。表中 gateway 为**参数**（默认 `IpfsResolver.defaultGateway`，门面传 `config.ipfsGateway`），非硬编码：

| 输入 `rawUrl` | `baseUrl` | 结果 | 说明 |
| --- | --- | --- | --- |
| nil / 空白 | — | nil | |
| 以 `{`/`[` 开头（像 JSON） | — | nil | `looksLikeJsonPayload` |
| `ipfs://…` / `/ipfs/…` / `ipfs/…` / 裸 CID | — | `https://ipfs.jccdex.cn/ipfs/<CID/path>` | §4.1 |
| `http(s)://…/ipfs/…` | — | 同上（换默认网关） | `canonicalizeHttpIpfsUrl` |
| `http://…` / `https://…` | — | 原样（trim） | |
| `data:…` | — | 原样 | `isLoadableRemoteAssetUrl` 放行 |
| `//host/a.png` / `/a.png` / `a.png`（相对） | `https://x/meta.json` | `URL(URL(base), raw).toString()` | `resolveRelativeAssetUrl`：**标准 URL 相对解析**（含协议相对） |
| 其他（无 base 的裸路径） | — | 原样返回 | Kotlin 现状：`resolveRelativeAssetUrl` 无 base 时返回 rawValue（**不判 nil**） |

> 与早期草案的差异（已按源码修正）：Kotlin 对**无 base 的不可解析路径返回原样**而非 nil；`data:` 放行；http(s) 中含 `/ipfs/` 路径会被**强制换到默认网关**。

**`looksLikeImageAssetUrl`**（`resolveRemoteImageUrl` 第 3 步用）：`data:` 前缀，或路径后缀 ∈ {`.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`, `.svg`, `.avif`, `.bmp`}（大小写不敏感）。

## 6. 安全

- **SSRF（对齐 Kotlin `SsrfGuard` + Swift 修正 DNS rebinding）**：拉取前 `SsrfGuard.check(url)`——scheme http/https、host 非空、**DNS 解析失败 fail-closed**、拒绝回环/私网/链路本地（`localhost`、127.0.0.0/8、10/8、172.16/12、192.168/16、169.254/16、::1、fe80::/10、fc00::/7），并补 IPv4-mapped IPv6（`::ffff:a.b.c.d` 映射回 IPv4 再判）、`0.0.0.0`/`255.255.255.255`、`100.64.0.0/10`（CGNAT）；**公网 IP 放行**（Kotlin 测试：`https://8.8.8.8/metadata.json` 通过）。**Swift 必须修正 Kotlin 的 check-then-connect 间隙（DNS rebinding / TOCTOU）**：① 解析**全部**地址（`getaddrinfo` 全量），任一私网/回环/链路本地即拒；② 建连策略三选一——`NWConnection` 连已校验 IP + TLS server-name（证书按原主机名校验）／按主机名建连后复验对端 IP／明确接受残余风险；⚠️ **HTTPS 不能简单「pin IP + Host 头」**（证书校验会失败，除非危险地 override server trust）；**URLSession 无对端 IP API，方案 ② 仅 `NWConnection` 可行**——默认 `SwiftNftConfig.httpClient` 即 URLSession，默认取舍采用 ③（文档化残余风险），详见 02 §4/§8。
- **重定向**：元数据/图片拉取**不跟随重定向**（Kotlin `instanceFollowRedirects = false`；Swift 用 delegate-backed URLSession，`willPerformHTTPRedirection` 返回 nil——**勿用 `URLSession.shared`**，其无 delegate、会静默跟随）——重定向是 SSRF 绕过常见路径；SWTC RPC 节点可信、**直接跟随重定向**（Kotlin `instanceFollowRedirects = true`；`SwtcTokenUriResolver` 无 delegate，与 `EthTokenUriResolver` 同策略）。
- **注入的 RPC 节点也要过 `SsrfGuard`**：Kotlin 节点硬编码可信故不查；Swift 可注入，建连前对节点 URL 做 http/https + 公网校验（注入节点由宿主负责信任边界）。
- **响应体上限**：Swift 增强——元数据/图片 body 设 2 MiB 上限（Kotlin `readText()` 无上限属现状），防恶意元数据撑爆内存；`data:` URL 解码同样设上限（上限归属：本模块解码校验时适用；原样透传字符串时由渲染侧负责，见 02 §8）。
- **`data:` URL 类型**：`isSupportedRemoteAssetUrl` 放行任何 `data:` 前缀（对齐 Kotlin 纯函数），但 `resolveCredentialImage` 直出前用**独立的 `isDataImageUrl` 检查**仅放行 `data:image/*`（设计决策，勿收紧公开函数）——只挡 HTML/JS，**挡不住 `image/svg+xml` 脚本**；宿主渲染第三方图片须用 `UIImage`/`CGImage` 解码（不执行脚本）、勿用 `WKWebView`。
- **不记录 payload**：日志只打 scheme/host，不打元数据 body（可能含头像、社交链接等隐私）。
- **无密钥面**：本模块不接触私钥/秘钥，无桥传输面（与 SwiftWallet/SwiftDid 密钥经桥的风险隔离）。
- **不面向任意地址**：头像候选只从**本钱包账户**的本地持仓表读取（宿主同步），复述 M3 边界：DApp 面任意地址 NFT 枚举（`eth_requestNfts` / `swtc_requestNfts`）属 SwiftDappConnect `NftProvider` 范畴，由宿主校验「address ∈ 已授权账户」。
