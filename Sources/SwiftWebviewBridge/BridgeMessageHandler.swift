import Foundation
import WebKit

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
        switch message.name {
        case "onPromiseResult":
            guard
                let body = message.body as? [String: Any],
                let id = body["id"] as? String,
                let resultJson = body["resultJson"] as? String
            else { return }
            self.delegate?.onPromiseResult(id: id, resultJson: resultJson)
        case "onBridgeReady":
            self.delegate?.onBridgeReady()
        case "onConsole":
            guard
                let body = message.body as? [String: Any],
                let level = body["level"] as? String,
                let messageText = body["message"] as? String
            else { return }
            self.delegate?.onConsole(level: level, message: messageText)
        default:
            break
        }
    }
}
