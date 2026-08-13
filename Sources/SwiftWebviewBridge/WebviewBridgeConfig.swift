import Foundation

/// 模块自带资源 bundle。SPM 目标内使用 `Bundle.module`，
/// 宿主 App 若自行拷贝资产，可在构造 Config 时传入 `Bundle.main` 覆盖。
public enum WebviewBridgeResources {
    public static var bundle: Bundle {
        .module
    }
}

public struct WebviewBridgeConfig {
    public var bridgeFileName: String
    public var resourceBundle: Bundle
    public var jsInterfaceName: String
    public var consoleTag: String
    public var allowsConsoleForwarding: Bool

    public init(
        bridgeFileName: String,
        resourceBundle: Bundle = WebviewBridgeResources.bundle,
        jsInterfaceName: String = "JSBridge",
        consoleTag: String = "WebViewConsole",
        allowsConsoleForwarding: Bool = false
    ) {
        self.bridgeFileName = bridgeFileName
        self.resourceBundle = resourceBundle
        self.jsInterfaceName = jsInterfaceName
        self.consoleTag = consoleTag
        self.allowsConsoleForwarding = allowsConsoleForwarding
    }

    public static func bridge(
        named name: String,
        in bundle: Bundle = WebviewBridgeResources.bundle
    ) -> WebviewBridgeConfig {
        WebviewBridgeConfig(bridgeFileName: name + ".html", resourceBundle: bundle)
    }
}
