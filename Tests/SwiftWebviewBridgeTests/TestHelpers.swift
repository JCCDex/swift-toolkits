import Foundation

/// 轮询等待条件成立（让主 actor 上的挂起任务有机会执行）。
@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// 从 `PromiseBridge.call(method, params, "uuid");` 中提取 promise id。
func extractPromiseId(from script: String) throws -> String {
    let regex = try NSRegularExpression(pattern: #",\s*"([^"]+)"\);\s*$"#)
    let ns = script as NSString
    guard let match = regex.firstMatch(in: script, range: NSRange(location: 0, length: ns.length)) else {
        throw NSError(
            domain: "SwiftWebviewBridgeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No promise id in script: \(script)"]
        )
    }
    return ns.substring(with: match.range(at: 1))
}
