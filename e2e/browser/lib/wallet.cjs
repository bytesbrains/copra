// The tier-1 wallet (#46): a thin EIP-1193 provider injected as window.ethereum. Its logic runs here, in
// the test process, so a test can see every request the page makes (layer 2) and act as the user:
// reject, switch account or chain. Transactions are sent to anvil with eth_sendTransaction from its
// unlocked dev accounts, so every one really executes; only the wallet's own UI is skipped (tier 2, #50).
const { ethers } = require('ethers');

// Installed before any page script runs, on every navigation. It only forwards to the test process.
const SHIM = `(() => {
  const listeners = {};
  window.ethereum = {
    async request({ method, params }) {
      const r = await window.__copraWallet(method, params === undefined ? [] : params);
      if (r.error) {
        const e = new Error(r.error.message);
        e.code = r.error.code;
        if (r.error.data !== undefined) e.data = r.error.data;
        throw e;
      }
      return r.result;
    },
    on(event, fn) { (listeners[event] ||= []).push(fn); return this; },
    removeListener(event, fn) { listeners[event] = (listeners[event] || []).filter((f) => f !== fn); return this; },
  };
  window.__copraWalletEmit = (event, arg) => (listeners[event] || []).forEach((fn) => fn(arg));
})();`;

const rpcError = (code, message, data) => Object.assign(new Error(message), { code, data });
const hex = (n) => '0x' + n.toString(16);
const RPC_TIMEOUT_MS = 30_000;

class Wallet {
  constructor(page, { rpcUrl, accounts, chainId, knownChains = [chainId] }) {
    this.page = page;
    this.rpcUrl = rpcUrl;
    this.accounts = accounts.map(ethers.getAddress);
    this.selected = this.accounts[0];
    this.chainId = chainId;
    this.knownChains = new Set(knownChains);
    this.connected = false;
    this.requests = []; // every request the page made, in order: { method, params }
    this.reject = new Set(); // methods the "user" rejects (4001)
    this.beforeSend = null; // async (tx) => {}: runs after the user signs, before the wallet broadcasts
    this.nextId = 1;
  }

  static async install(page, opts) {
    const wallet = new Wallet(page, opts);
    await page.exposeBinding('__copraWallet', (_source, method, params) => wallet.handle(method, params));
    await page.addInitScript(SHIM);
    return wallet;
  }

  /** Requests for `method`, in order. */
  calls(method) {
    return this.requests.filter((r) => r.method === method);
  }

  /** The transactions the page asked the wallet to send: { from, to, data, hash }. */
  get sent() {
    return this.calls('eth_sendTransaction').filter((r) => r.hash).map((r) => ({ ...r.params[0], hash: r.hash }));
  }

  async handle(method, params) {
    const entry = { method, params };
    this.requests.push(entry);
    try {
      const result = await this.dispatch(method, params, entry);
      return { result: result === undefined ? null : result };
    } catch (e) {
      return { error: { code: e.code ?? -32603, message: e.message, data: e.data } };
    }
  }

  async dispatch(method, params, entry) {
    if (this.reject.has(method)) throw rpcError(4001, 'User rejected the request.');
    switch (method) {
      case 'eth_requestAccounts':
        this.connected = true;
        return [this.selected];
      case 'eth_accounts':
        return this.connected && this.selected ? [this.selected] : [];
      case 'eth_chainId':
        return hex(this.chainId);
      case 'net_version':
        return String(this.chainId);
      case 'wallet_switchEthereumChain': {
        const id = Number(params[0].chainId);
        if (!this.knownChains.has(id)) throw rpcError(4902, `Unrecognized chain ID "${params[0].chainId}".`);
        await this.setChain(id);
        return null;
      }
      case 'wallet_addEthereumChain': {
        const id = Number(params[0].chainId);
        this.knownChains.add(id);
        await this.setChain(id);
        return null;
      }
      case 'wallet_watchAsset':
        return true;
      case 'eth_sendTransaction': {
        // A real wallet only signs for the account it has selected.
        const from = ethers.getAddress(params[0].from);
        if (!this.connected || from !== this.selected) {
          throw rpcError(4100, `The requested account ${from} has not been authorized by the user.`);
        }
        if (this.beforeSend) await this.beforeSend(params[0]);
        entry.hash = await this.rpc(method, params);
        return entry.hash;
      }
      default:
        return this.rpc(method, params);
    }
  }

  async rpc(method, params) {
    // Bounded, so a hung node fails the request by name instead of the test at its timeout.
    const res = await fetch(this.rpcUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: this.nextId++, method, params }),
      signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
    }).catch((e) => { throw rpcError(-32603, `${method}: ${this.rpcUrl} did not answer (${e.message})`); });
    const body = await res.json();
    if (body.error) throw rpcError(body.error.code, body.error.message, body.error.data);
    return body.result;
  }

  async emit(event, arg) {
    // The page may be navigating (chainChanged reloads it): an event lost with it is a lost event in a
    // real wallet too.
    await this.page.evaluate(([e, a]) => window.__copraWalletEmit?.(e, a), [event, arg]).catch(() => {});
  }

  async setChain(id) {
    this.chainId = id;
    await this.emit('chainChanged', hex(id));
  }

  /** The user selects another account in the wallet, or disconnects every account (null). */
  async selectAccount(address) {
    this.selected = address ? ethers.getAddress(address) : null;
    await this.emit('accountsChanged', this.selected ? [this.selected] : []);
  }
}

module.exports = { Wallet };
