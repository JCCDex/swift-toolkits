/**
 * CCDAO EIP-1193 Provider - iOS 变体
 *
 * 与 Android 版 ccdao-eip1193-provider.js 的唯一差异在传输层（C-03）：
 * - Android：window._tw_.postMessage(json)，响应经 WebMessagePort 握手回传
 * - iOS：window.webkit.messageHandlers._tw_.postMessage(json)，native 经
 *   evaluateJavaScript 调 window._ccdaoSettle(nonce, payloadJson, token) 回传
 *
 * 对 Kotlin 的显式改进：
 * - 请求队列条目存 { callback, timer }，settleRequest 时 clearTimeout，防止 timer 泄漏
 * - 每个请求 60s 超时兜底：native 崩溃/无法回传时 Promise 不永久挂起
 * - _tw_ 不可用时统一回 { error: { code: -1, message: 'Bridge not available' } }
 *
 * 安全加固（M1/M2，相对 Kotlin 的显式偏离）：
 * - 状态全部收进 IIFE 闭包：不再暴露可写的 window._ccdaoProviderState，
 *   页面 JS 无法直接篡改 chainId / accounts / listeners
 * - native → JS 的唯一入口 _ccdaoSettle / _ccdaoNative 均：
 *   a) 校验桥接 token（由 DAppConnectSdk.loadProviderJs(token:) 注入闭包），
 *      页面 JS 读不到 token，无法伪造 native 响应或状态推送；
 *   b) 用 Object.defineProperty 冻结（不可写/不可删/不可枚举），
 *      页面 JS 无法覆盖或删除回传入口做劫持；
 *   c) 请求级 nonce 继续把响应绑定到唯一挂起请求。
 *   token 缺失/为空时所有 native 回传 fail-closed（不影响出站请求）。
 */
(function () {
    // 防止重复注入
    if (window.ethereum && window.ethereum._ccdaoProvider) {
        return;
    }

    // 桥接 token：由 DAppConnectSdk.loadProviderJs(token:) 注入；null/空 → fail-closed。
    const BRIDGE_TOKEN = /*__CCDAO_BRIDGE_TOKEN__*/ null;

    function bridgeAuth(token) {
        return typeof BRIDGE_TOKEN === 'string' && BRIDGE_TOKEN.length > 0 && token === BRIDGE_TOKEN;
    }

    // 闭包内状态（M2）：页面 JS 不可达、不可改。
    const state = {
        chainId: '0x1',
        chainIdDecimal: 1,
        accounts: [],
        listeners: {}
    };

    // 请求队列留在 IIFE 闭包内：不再挂 window，避免页面脚本伪造/劫持回调。
    const requestQueue = {};
    let requestId = 0;
    const REQUEST_TIMEOUT_MS = 60000;

    function settleRequest(nonce, response) {
        const entry = requestQueue[nonce];
        if (!entry) {
            return;
        }
        delete requestQueue[nonce];
        clearTimeout(entry.timer);
        entry.callback(response);
    }

    // ipfs_personalSign 的首个参数是二进制（ArrayBuffer/TypedArray），
    // 直接 JSON.stringify 会丢失（ArrayBuffer→{}），统一归一化为普通字节数组传给原生。
    function normalizeBinaryParams(method, params) {
        if (method !== 'ipfs_personalSign' || !Array.isArray(params) || params.length === 0) {
            return params;
        }
        const d = params[0];
        let u8 = null;
        if (d instanceof ArrayBuffer) {
            u8 = new Uint8Array(d);
        } else if (ArrayBuffer.isView(d)) {
            u8 = new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
        } else if (Array.isArray(d)) {
            u8 = Uint8Array.from(d);
        } else if (d && typeof d === 'object') {
            u8 = Uint8Array.from(Object.values(d));
        }
        if (!u8) {
            return params;
        }
        return [Array.from(u8), ...params.slice(1)];
    }

    // crypto.randomUUID() polyfill
    function randomUUID() {
        return crypto.randomUUID?.() ??
            'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
                const r = crypto.getRandomValues(new Uint8Array(1))[0];
                return (c === 'x' ? r & 15 : (r & 0x3 | 0x8)).toString(16);
            });
    }

    // 发送请求到 Native（iOS：经 messageHandlers reply 回调回传响应）
    function sendToNative(method, params, callback) {
        const id = ++requestId;
        const nonce = randomUUID();
        params = normalizeBinaryParams(method, params);

        // 先登记请求 + 60s 超时兜底（settleRequest 会 clearTimeout）
        requestQueue[nonce] = {
            callback: callback,
            timer: setTimeout(function () {
                settleRequest(nonce, {
                    error: { code: -1, message: 'Native bridge timeout' }
                });
            }, REQUEST_TIMEOUT_MS)
        };

        const message = JSON.stringify({
            name: method,
            network: method.startsWith('swtc_') ? 'swtc' :
                     method.startsWith('eth_') || method.startsWith('wallet_') || method.startsWith('personal_') ? 'eth' : 'ccdao',
            id: String(id),
            nonce: nonce,
            params: params || []
        });

        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers._tw_) {
            window.webkit.messageHandlers._tw_.postMessage(message);
        } else {
            console.error('[CCDAO EIP-1193] _tw_ not available');
            // 对 Kotlin 的显式偏离：统一为 {code,message} 结构（Kotlin 回字符串）
            settleRequest(nonce, {
                error: { code: -1, message: 'Bridge not available' }
            });
        }
    }

    // EIP-1193 Provider（getters 读闭包 state）
    const provider = {
        _ccdaoProvider: true,
        isMetaMask: true,

        // 当前链 ID（动态属性）
        get chainId() {
            return state.chainId;
        },

        // 当前网络版本（动态属性）
        get networkVersion() {
            return String(state.chainIdDecimal);
        },

        // 当前选中地址
        get selectedAddress() {
            return state.accounts[0] || null;
        },

        // 检查是否已连接
        isConnected: function () {
            return state.accounts.length > 0;
        },

        // EIP-1193 request 方法
        request: function (args) {
            const method = args.method;
            const params = args.params || [];

            // 拦截 eth_chainId，返回当前状态
            if (method === 'eth_chainId') {
                return Promise.resolve(state.chainId);
            }

            // 拦截 eth_accounts，返回当前账户
            if (method === 'eth_accounts') {
                return Promise.resolve(state.accounts);
            }

            // 拦截 eth_requestAccounts
            if (method === 'eth_requestAccounts') {
                return new Promise(function (resolve, reject) {
                    sendToNative('eth_requestAccounts', [], function (response) {
                        if (response.error) {
                            reject(response.error);
                        } else {
                            state.accounts = response.result || [];
                            resolve(state.accounts);
                        }
                    });
                });
            }

            // 其他请求转发到 Native
            return new Promise(function (resolve, reject) {
                sendToNative(method, params, function (response) {
                    if (response.error) {
                        reject(response.error);
                        // 如果链不支持，触发错误
                        if (method === 'wallet_switchEthereumChain' && response.error.code === 4902) {
                            provider._emitError('wallet_switchEthereumChain', response.error);
                        }
                    } else {
                        resolve(response.result);
                    }
                });
            });
        },

        // EIP-1193 事件系统
        on: function (event, handler) {
            if (!state.listeners[event]) {
                state.listeners[event] = [];
            }
            state.listeners[event].push(handler);
        },

        removeListener: function (event, handler) {
            if (state.listeners[event]) {
                const index = state.listeners[event].indexOf(handler);
                if (index > -1) {
                    state.listeners[event].splice(index, 1);
                }
            }
        },

        removeAllListeners: function (event) {
            if (event) {
                delete state.listeners[event];
            } else {
                state.listeners = {};
            }
        },

        // 内部 emit 方法
        emit: function (event, data) {
            const handlers = state.listeners[event];
            if (handlers) {
                handlers.forEach(function (handler) {
                    try {
                        handler(data);
                    } catch (e) {
                        console.error('[CCDAO EIP-1193] Handler error:', e);
                    }
                });
            }
        },

        _emitError: function (method, error) {
        }
    };

    // ── native → JS 安全入口（M1/M2） ──

    // _ccdaoSettle：native 响应投递。需正确 token + 挂起 nonce 才生效；
    // 页面 JS 拿不到 token（闭包私有）且 nonce 不可读，无法伪造 native 响应。
    function settleFromNative(nonce, payloadJson, token) {
        if (!bridgeAuth(token)) {
            return;
        }
        let msg;
        try {
            msg = JSON.parse(payloadJson);
        } catch (_) {
            return;
        }
        if (!msg || typeof msg.nonce !== 'string' || msg.nonce !== nonce) {
            return;
        }
        if (Object.prototype.hasOwnProperty.call(msg, 'error')) {
            settleRequest(msg.nonce, { error: msg.error });
        } else {
            settleRequest(msg.nonce, { result: msg.result });
        }
    }

    // _ccdaoNative：native 状态推送统一入口（init / setAddress / setChainId）。
    // 页面 JS 无 token，无法伪造 accountsChanged / chainChanged 事件。
    function applyNativeState(kind, payload, token) {
        if (!bridgeAuth(token)) {
            return;
        }
        if (!payload || typeof payload !== 'object') {
            return;
        }
        switch (kind) {
            case 'init':
                if (typeof payload.chainId === 'string') {
                    state.chainId = payload.chainId;
                    state.chainIdDecimal = parseInt(payload.chainId, 16);
                }
                if (typeof payload.rpcUrl === 'string') {
                    state.rpcUrl = payload.rpcUrl;
                }
                break;
            case 'setAddress': {
                if (typeof payload.address !== 'string') {
                    return;
                }
                const oldAddress = state.accounts[0];
                state.accounts = [payload.address];
                if (oldAddress !== payload.address) {
                    provider.emit(payload.isSwtc ? 'swtcAccountsChanged' : 'accountsChanged', [payload.address]);
                }
                break;
            }
            case 'setChainId': {
                if (typeof payload.chainIdHex !== 'string') {
                    return;
                }
                const oldChainId = state.chainId;
                state.chainId = payload.chainIdHex;
                state.chainIdDecimal = parseInt(payload.chainIdHex, 16);
                if (typeof payload.rpcUrl === 'string') {
                    state.rpcUrl = payload.rpcUrl;
                }
                if (oldChainId !== payload.chainIdHex) {
                    provider.emit('chainChanged', payload.chainIdHex);
                }
                break;
            }
            default:
                break;
        }
    }

    // 冻结为不可写/不可删/不可枚举：页面 JS 无法覆盖或删除回传入口。
    function defineFrozen(name, fn) {
        try {
            Object.defineProperty(window, name, {
                value: fn,
                writable: false,
                configurable: false,
                enumerable: false
            });
        } catch (_) {
            // 页面预先以不可配置属性占用该名字（注入时序异常）：保持原样，
            // native 回传/推送将无法送达（fail-closed），不影响出站请求。
        }
    }
    defineFrozen('_ccdaoSettle', settleFromNative);
    defineFrozen('_ccdaoNative', applyNativeState);

    // 设置 window.ethereum
    window.ethereum = provider;
    // 兼容性设置
    window.eth = provider;

    // ── window.ccdao：CCDAO 专有 provider ──
    // 复用与 window.ethereum 相同的 sendToNative / 闭包 requestQueue / 事件系统。
    window.ccdao = window.ccdao || {};
    window.ccdao.isCCDAO = true;
    window.ccdao.request = function (args) {
        const method = args.method;
        const params = args.params || [];
        // eth_* 与 window.ethereum 保持一致的本地拦截
        if (method === 'eth_chainId') {
            return Promise.resolve(state.chainId);
        }
        if (method === 'eth_accounts') {
            return Promise.resolve(state.accounts);
        }
        if (method === 'eth_requestAccounts') {
            return new Promise(function (resolve, reject) {
                sendToNative('eth_requestAccounts', [], function (response) {
                    if (response.error) {
                        reject(response.error);
                    } else {
                        state.accounts = response.result || [];
                        resolve(state.accounts);
                    }
                });
            });
        }
        // 其余方法（swtc_/did_/ipfs_/web3_/*_requestNfts 等）直接转发原生
        return new Promise(function (resolve, reject) {
            sendToNative(method, params, function (response) {
                if (response.error) {
                    reject(response.error);
                } else {
                    resolve(response.result);
                }
            });
        });
    };
    // 事件系统与 window.ethereum 共享同一份 state.listeners
    window.ccdao.on = provider.on;
    window.ccdao.removeListener = provider.removeListener;
    window.ccdao.removeAllListeners = provider.removeAllListeners;
    window.ccdao.emit = provider.emit;

    // EIP-6963 支持
    const providerInfo = {
        uuid: 'ccdao-connector',
        name: 'CCDAO Connector',
        icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><circle cx="16" cy="16" r="16" fill="%234F46E5"/><text x="16" y="22" text-anchor="middle" fill="white" font-size="18" font-family="Arial">C</text></svg>',
        rdns: 'com.jccdex.ccdaoconnector'
    };

    function announceProvider() {
        const event = new CustomEvent('eip6963:announceProvider', {
            detail: Object.freeze({
                info: Object.freeze(providerInfo),
                provider: provider
            })
        });
        window.dispatchEvent(event);
    }

    window.addEventListener('eip6963:requestProvider', announceProvider);
    announceProvider();

    // 定期广播
    setInterval(announceProvider, 5000);
})();
