import Foundation
import WebKit

/// 桥消息通道名（Swift 侧 add/remove/分发统一入口，见 review 跨模块重复 2.2；
/// `BridgeScripts` 内 JS 适配脚本的同名通道字符串仍为字面量——JS 无法引用 Swift 常量）。
enum BridgeHandlerName: String {
    case promiseResult = "onPromiseResult"
    case bridgeReady = "onBridgeReady"
    case console = "onConsole"
}

@MainActor
protocol BridgeMessageHandlerDelegate: AnyObject {
    func onPromiseResult(id: String, resultJson: String)
    func onBridgeReady()
    func onConsole(level: String, message: String)
}

@MainActor
final class BridgeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: BridgeMessageHandlerDelegate?

    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch BridgeHandlerName(rawValue: message.name) {
        case .promiseResult:
            guard
                let body = message.body as? [String: Any],
                let id = body["id"] as? String,
                let resultJson = body["resultJson"] as? String
            else { return }
            self.delegate?.onPromiseResult(id: id, resultJson: resultJson)
        case .bridgeReady:
            self.delegate?.onBridgeReady()
        case .console:
            guard
                let body = message.body as? [String: Any],
                let level = body["level"] as? String,
                let messageText = body["message"] as? String
            else { return }
            self.delegate?.onConsole(level: level, message: messageText)
        case nil:
            break
        }
    }
}
