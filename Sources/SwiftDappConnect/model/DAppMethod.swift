import Foundation

/// DApp RPC 方法枚举，rawValue 与 Kotlin `DAppMethod` 的方法名字符串一致。
public enum DAppMethod: String, Sendable, CaseIterable {
    // SWTC
    case swtcRequestAccounts = "swtc_requestAccounts"
    case swtcSendTransaction = "swtc_sendTransaction"
    case swtcMultiSign = "swtc_multiSign"
    case swtcSignMessage = "swtc_signMessage"
    case swtcGetPublicKey = "swtc_getPublicKey"
    case swtcRequestNfts = "swtc_requestNfts"

    // ETH (EIP-1193)
    case ethAccounts = "eth_accounts"
    case ethRequestAccounts = "eth_requestAccounts"
    case ethChainId = "eth_chainId"
    case ethBlockNumber = "eth_blockNumber"
    case ethPersonalSign = "personal_sign"
    case ethPersonalEcRecover = "personal_ecRecover"
    case ethSignTypedData = "eth_signTypedData"
    case ethSignTypedDataV3 = "eth_signTypedData_v3"
    case ethSignTypedDataV4 = "eth_signTypedData_v4"
    case ethSendTransaction = "eth_sendTransaction"
    case ethSignTransaction = "eth_signTransaction"
    case ethGetEncryptionPublicKey = "eth_getEncryptionPublicKey"
    case ethDecrypt = "eth_decrypt"
    case ethRequestNfts = "eth_requestNfts"

    /// Wallet
    case walletSwitchEthereumChain = "wallet_switchEthereumChain"

    // DID / IPFS
    case didRequestAccountName = "did_requestAccountName"
    case didGetBase58PublicKey = "did_getBase58PublicKey"
    case didIssueCredential = "did_issueCredential"
    case ipfsPersonalSign = "ipfs_personalSign"
    case ipfsGetPublicKey = "ipfs_getPublicKey"

    /// Common
    case web3ClientVersion = "web3_clientVersion"

    case unknown

    public static func fromValue(_ value: String) -> DAppMethod {
        DAppMethod(rawValue: value) ?? .unknown
    }
}
