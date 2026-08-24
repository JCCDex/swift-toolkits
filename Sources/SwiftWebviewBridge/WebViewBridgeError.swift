import Foundation

public enum WebViewBridgeError: Error, Sendable, Equatable {
    case notInitialized
    case missingBridgeResource(String)
    case invalidParams
    case timeout
    case jsError(String)
    case invalidResponseFormat
    case malformedJSON(String)
    case webViewUnavailable
}
