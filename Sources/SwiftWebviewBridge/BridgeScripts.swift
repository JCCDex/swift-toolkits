import Foundation

enum BridgeScripts {
    /// 在页面任何脚本执行前注入，把 Kotlin 资产中的 `window.JSBridge` 旧接口
    /// 转发到 WebKit 消息通道，使 `*-bridge.js` 与 vendor 库无需修改即可运行。
    static func adapter(interfaceName: String) -> String {
        """
        (function () {
          'use strict';
          window.\(interfaceName) = {
            onPromiseResult: function (id, resultJson) {
              window.webkit.messageHandlers.onPromiseResult.postMessage({
                id: id,
                resultJson: resultJson
              });
            },
            onBridgeReady: function () {
              window.webkit.messageHandlers.onBridgeReady.postMessage(null);
            }
          };
        })();
        """
    }

    /// 可选：把 console 转发到原生（对应 Kotlin 默认关闭的 onConsoleMessage）。
    static let consoleForwarding = """
    (function () {
      var levels = ['log', 'info', 'warn', 'error', 'debug'];
      for (var i = 0; i < levels.length; i++) {
        (function (level) {
          var original = console[level];
          console[level] = function () {
            try {
              window.webkit.messageHandlers.onConsole.postMessage({
                level: level,
                message: Array.prototype.slice.call(arguments).map(String).join(' ')
              });
            } catch (e) {}
            if (original) original.apply(console, arguments);
          };
        })(levels[i]);
      }
    })();
    """
}
