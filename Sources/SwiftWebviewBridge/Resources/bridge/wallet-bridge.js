// PromiseBridge (loaded into the hidden WebView)
// - Kotlin -> JS 的调用通过 PromiseBridge.call(method, params, id)
// - JS 执行逻辑后必须回调 window.JSBridge.onPromiseResult(id, JSON.stringify({ result: ... }))
//   或回调 window.JSBridge.onPromiseResult(id, JSON.stringify({ error: "..." }))

(function (global) {

  // Set true only for local bridge debugging. Must stay false in release assets.
  const DEBUG = false;

  const jccWallet = window.jcc_wallet;
  const HDWallet = jccWallet.HDWallet;
  const jtWallet = jccWallet.jtWallet;
  const ethWallet = jccWallet.ethWallet;
  const jingtumLib = window.jingtum_lib;
  const serializePayment = jingtumLib.serializePayment;
  const serialize721Payment = jingtumLib.serialize721Payment;
  const serializeCreateOrder = jingtumLib.serializeCreateOrder;
  const serializeCancelOrder = jingtumLib.serializeCancelOrder;
  const BIP44Chain = jccWallet.BIP44Chain;
  const ethSigUtil = window.ethSigUtil;
  const { hexToBytes, bytesToHex, prepareTransaction } = window.ethereumjsTx;

  const wallet = new jingtumLib.Wallet("jingtum")

  // EVM 系列链常量
  const EVM_CHAINS = [
    BIP44Chain.ETH,
    BIP44Chain.BSC,
    BIP44Chain.POLYGON,
    BIP44Chain.ARB1,
    BIP44Chain.BASE,
    BIP44Chain.MOAC,
    BIP44Chain.HECO
  ];

  // 判断是否为 EVM 链
  function isEvmChain(chain) {
    return EVM_CHAINS.includes(chain);
  }

  function normalizePrivateKey(privateKey, chain) {
    // if is ripple or swtc, return itself.
    if (chain === BIP44Chain.RIPPLE || chain === BIP44Chain.SWTC) {
      return privateKey;
    }
    // if is evm or tron, return 64 length hex string.
    return privateKey.length === 66 ? privateKey.substring(2) : privateKey;
  }

  function normalizePublicKey(publicKey, chain) {
    if (chain === BIP44Chain.RIPPLE || chain === BIP44Chain.SWTC) {
      return publicKey;
    }
    // if is evm or tron, return 64 length hex string.
    return publicKey.length === 66 ? publicKey.substring(2) : publicKey;
  }

  function normalizeKeypair(keypair, chain) {
    return {
      privateKey: normalizePrivateKey(keypair.privateKey, chain),
      publicKey: normalizePublicKey(keypair.publicKey, chain)
    };
  }

  const methods = {
    // 验证助记词是否有效
    validateMnemonic(params) {
      const { mnemonic, language = "english" } = params;
      try {
        HDWallet.fromMnemonic({ mnemonic, language });
        return true;
      } catch (_) {
        return false;
      }
    },
    // 生成助记词
    generateMnemonic(params) {
      const { length = 128, language = "english" } = params || {};
      const mnemonic = HDWallet.generateMnemonic(length, language);
      return {
        value: mnemonic,
        language
      };
    },
    // 派生子钱包
    deriveChild(params) {
      const { mnemonic, chain, account = 0, change = 0, index = 0, language = "english" } = params;
      const hd = HDWallet.fromMnemonic({ mnemonic, language });
      const child = hd.deriveWallet({
        chain: chain,
        account: account,
        change: change,
        index: index
      });

      const path = child.path();

      return {
        chain: chain,
        address: child.address(),
        keypair: normalizeKeypair(child.keypair(), chain),
        path: {
          chain: path.chain & 0x7FFFFFFF,
          account: path.account,
          change: path.change,
          index: path.index
        }
      };
    },
    // 从助记词获取 HD 钱包信息
    hdWalletFromMnemonic(params) {
      const { mnemonic, chains = [], language = "english" } = params;

      // 从助记词获取根账户
      const hd = HDWallet.fromMnemonic({ mnemonic, language });
      const address = hd.address();
      const rootKeypair = hd.keypair();

      // 派生所有子账户
      const accounts = chains.map(chain => {
        const child = hd.deriveWallet({
          chain,
          account: 0,
          change: 0,
          index: 0
        });
        const path = child.path();
        return {
          chain,
          address: child.address(),
          keypair: normalizeKeypair(child.keypair(), chain),
          path: {
            chain: path.chain & 0x7FFFFFFF,
            account: path.account,
            change: path.change,
            index: path.index
          }
        };
      });

      return {
        mnemonic,
        language,
        address,
        keypair: normalizeKeypair(rootKeypair, BIP44Chain.SWTC),
        accounts: accounts
      };
    },
    // 传统钱包从助记词派生地址（与 HD 钱包派生方式不同）
    deriveFromMnemonic(params) {
      const { mnemonic, chain, account = 0, change = 0, index = 0, language = "english" } = params;

      let address;
      let keypair;
      const hd = HDWallet.fromMnemonic({ mnemonic, language });
      let path

      // SWTC 链使用 HDWallet 的根地址
      if (chain === BIP44Chain.SWTC) {
        address = hd.address();
        keypair = hd.keypair();
        path = hd.path();
      }
      // EVM 系列链使用 HDWallet 派生
      else if (isEvmChain(chain)) {
        const child = hd.deriveWallet({
          chain: chain,
          account: account,
          change: change,
          index: index
        });
        address = child.address();
        keypair = child.keypair();
        path = child.path();
      }
      // 其他链暂不支持
      else {
        throw new Error('Unsupported chain for mnemonic derivation');
      }

      return {
        address,
        mnemonic: {
          value: mnemonic,
          language
        },
        keypair: normalizeKeypair(keypair, chain),
        path: {
          chain: path.chain & 0x7FFFFFFF,
          account: path.account,
          change: path.change,
          index: path.index
        }
      };
    },
    // 从私钥/Secret派生地址（传统钱包导入）
    deriveFromPrivateKey(params) {
      const { privateKey, chain } = params;
      let address;
      let keypair;

      // SWTC 链使用 jtWallet
      if (chain === BIP44Chain.SWTC) {
        address = jtWallet.getAddress(privateKey);
        keypair = jtWallet.getKeyPairFromPrivateKey(privateKey);
      }
      // EVM 系列链使用 ethWallet
      else if (isEvmChain(chain)) {
        address = ethWallet.getAddress(privateKey);
        keypair = ethWallet.getKeyPairFromPrivateKey(privateKey);
      }
      // 其他链暂不支持直接私钥导入
      else {
        throw new Error('Unsupported chain for private key derivation');
      }

      return {
        address,
        // 针对swtc和ripple
        secret: privateKey,
        keypair: normalizeKeypair(keypair, chain)
      };
    },
    // 验证私钥是否有效
    validatePrivateKey(params) {
      const { privateKey, chain } = params;

      // SWTC 链使用 jtWallet
      if (chain === BIP44Chain.SWTC) {
        return jtWallet.isValidSecret(privateKey);
      }

      // EVM 链使用 ethWallet
      if (isEvmChain(chain)) {
        return ethWallet.isValidSecret(privateKey);
      }

      return false;
    },
    // 从已有助记词导入并派生所有子账户
    // SWTC 交易相关方法 (from main)
    buildSwtcPayment(params) {
      const { address, amount, to, token, memo } = params;
      const payment = serializePayment(
        address,
        amount,
        to,
        token,
        memo,
        wallet.getFee(),
        wallet.getCurrency(),
        wallet.getIssuer()
      );
      return payment;
    },

    buildSwtcNftTransfer(params) {
      const { address, to, tokenId, memo } = params;
      const tx = serialize721Payment(address, to, tokenId, wallet.getFee(), memo);
      return tx;
    },

    buildSwtcCreateOrder(params) {
      const { address, amount, base, counter, sum, type, platform, issuer } = params;
      const tx = serializeCreateOrder(
        address,
        amount,
        base === "SWTC" ? "SWT" : base,
        counter === "SWTC" ? "SWT" : counter,
        sum,
        type,
        platform,
        wallet.getCurrency(),
        wallet.getFee(),
        issuer || wallet.getIssuer()
      );
      return tx;
    },
    buildSwtcCancelOrder(params) {
      const { address, sequence } = params;
      const tx = serializeCancelOrder(address, sequence, wallet.getFee());
      return tx;
    },

    signSwtcTransaction(params) {
      const { secret } = params;
      delete params.secret;
      const signedTx = wallet.sign(params, secret);
      return signedTx;
    },
    // 验证SWTC地址是否有效
    isValidAddress(params) {
      const { address } = params;
      return jtWallet.isValidAddress(address);
    },
    // 签名消息
    signMessage(params) {
      const { address, message, secret } = params;
      if (!jtWallet.isValidAddress(address)) {
        throw new Error('Invalid SWTC address');
      }
      if (!secret) {
        throw new Error('Secret is required for signing');
      }

      const walletInstance = new wallet.wallet(secret);

      const signature = walletInstance.sign(message);

      return signature;
    },

    // 签名交易
    signTransaction(params) {
      const { tx, secret } = params;

      if (!secret) {
        throw new Error('Secret is required for transaction signing');
      }

      if (!tx) {
        throw new Error('Transaction object (tx) is required');
      }


      // 使用 wallet.sign 签名
      const signedTx = wallet.sign(tx, secret);


      return signedTx.blob;
    },
    // 多签
    multiSign(params) {
      const { tx, secret } = params;

      if (!secret) {
        throw new Error('Secret is required for multi-signing');
      }

      // 执行多重签名，直接返回 wallet.multiSign 的结果
      const multiSignResult = wallet.multiSign(tx, secret);

      return multiSignResult;
    },

    // ETH RPC Methods
    // Personal sign - 签名消息
    personalSign(params) {
      const { privateKey, data } = params;
      if (!privateKey) {
        throw new Error('Private key is required for signing');
      }

      if (!data) {
        throw new Error('Data is required for signing');
      }

      const privateKeyBytes = hexToBytes(privateKey);

      // 使用 eth-sig-util 签名
      const signature = ethSigUtil.personalSign({
        privateKey: privateKeyBytes,
        data: data
      });
      return signature;
    },
    signTypedData(params) {
      const { privateKey, data, version } = params;

      if (!privateKey) {
        throw new Error('Private key is required for signing');
      }

      if (!data) {
        throw new Error('Data is required for signing');
      }

      const typedData = typeof data === 'string' ? JSON.parse(data) : data;
      const privateKeyBytes = hexToBytes(privateKey);
      const signature = ethSigUtil.signTypedData({
        privateKey: privateKeyBytes,
        data: typedData,
        version: version
      });
      return signature;
    },
    recoverTypedSignature(params) {
      const { data, signature, version } = params;
      const typedData = typeof data === 'string' ? JSON.parse(data) : data;
      const recoveredAddr = ethSigUtil.recoverTypedSignature({
        data: typedData,
        signature: signature,
        version: version
      });
      return recoveredAddr;
    },
    recoverPersonalSignature(params) {
      const { data, signature } = params;
      const recoveredAddr = ethSigUtil.recoverPersonalSignature({
        data: data,
        signature: signature
      });
      return recoveredAddr;
    },
    getEncryptionPublicKey(params) {
      const { privateKey } = params;
      if (!privateKey) {
        throw new Error('Private key is required to get encryption public key');
      }

      const publicKey = ethSigUtil.getEncryptionPublicKey(privateKey);

      return publicKey;
    },
    decrypt(params) {
      let { privateKey, data } = params;

      if (data.startsWith("0x")) {
        data = JSON.parse(new TextDecoder().decode(hexToBytes(data.slice(2))))
      }

      const decryptedMessage = ethSigUtil.decrypt({
        privateKey: privateKey,
        encryptedData: data
      });

      return decryptedMessage;
    },


    // Sign ETH transaction
    signEthTransaction(params) {
      const { privateKey, tx } = params;

      if (!privateKey) {
        throw new Error('Private key is required for transaction signing');
      }

      if (!tx) {
        throw new Error('Transaction object (tx) is required');
      }


      const privateKeyBytes = hexToBytes(privateKey);


      const transaction = prepareTransaction(tx.chainId, tx)

      const signedTx = transaction.sign(privateKeyBytes);

      const serializedTx = bytesToHex(signedTx.serialize());
      return serializedTx;
    },

  }

  global.PromiseBridge = {
    call: async function (method, params, id) {
      if (DEBUG) console.log('[PromiseBridge] call:', method, 'id:', id);
      try {
        if (!method || typeof method !== 'string') {
          throw new Error('invalid method');
        }
        const fn = methods[method];
        if (!fn) {
          throw new Error('no such method: ' + method);
        }
        if (DEBUG) console.log('[PromiseBridge] executing method:', method);
        const result = await fn(params);
        if (DEBUG) console.log('[PromiseBridge] method result:', method, 'success');

        if (window.JSBridge && window.JSBridge.onPromiseResult) {
          window.JSBridge.onPromiseResult(id, JSON.stringify({ result: result }));
        } else {
          if (DEBUG) console.error('[PromiseBridge] JSBridge.onPromiseResult not available');
        }
      } catch (err) {
        if (DEBUG) console.error('[PromiseBridge] error:', err);
        if (window.JSBridge && window.JSBridge.onPromiseResult) {
          window.JSBridge.onPromiseResult(id, JSON.stringify({ error: (err && err.message) ? err.message : String(err) }));
        }
      }
    }
  };

  if (window.JSBridge && window.JSBridge.onBridgeReady) {
    try {
      window.JSBridge.onBridgeReady();
    } catch (_) {
    }
  }

})(window);
