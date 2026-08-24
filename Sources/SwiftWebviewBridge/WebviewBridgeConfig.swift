import Foundation

/// 模块自带资源 bundle。SPM 目标内使用 `Bundle.module`，
/// 宿主 App 若自行拷贝资产，可在构造 `WebviewBridgeClient(bundle:)` 时传入 `Bundle.main` 覆盖。
public enum WebviewBridgeResources {
    public static var bundle: Bundle {
        .module
    }
}

public struct WebviewBridgeConfig {
    public var bridgeFileName: String
    public var jsInterfaceName: String
    public var consoleTag: String
    public var allowsConsoleForwarding: Bool

    public init(
        bridgeFileName: String,
        jsInterfaceName: String = "JSBridge",
        consoleTag: String = "WebViewConsole",
        allowsConsoleForwarding: Bool = false
    ) {
        self.bridgeFileName = bridgeFileName
        self.jsInterfaceName = jsInterfaceName
        self.consoleTag = consoleTag
        self.allowsConsoleForwarding = allowsConsoleForwarding
    }

    /// 便捷构造：仅取文件名（资源 bundle 由 `WebviewBridgeClient.init(bundle:)` 决定，
    /// 见 review SwiftWebviewBridge P1#4——原 `resourceBundle` 配置只写不读，已删）。
    public static func bridge(named name: String) -> WebviewBridgeConfig {
        WebviewBridgeConfig(bridgeFileName: name + ".html")
    }
}
