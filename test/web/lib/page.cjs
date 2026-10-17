// A minimal fake DOM that runs web/assets/*.js the way the browser does: classic scripts, in
// index.html's order, in one shared global scope. Shared by test/web/scripts.test.cjs (offline,
// against a fake ethers) and e2e/web/check-web.cjs (the served page, against the e2e chain).
const vm = require('node:vm');

function fakeElement(id) {
  const el = {
    id, tagName: 'DIV', textContent: '', className: '', value: '', disabled: false,
    children: [], listeners: {}, attrs: {},
    classList: {
      set: new Set(),
      add(...c) { c.forEach((x) => this.set.add(x)); },
      remove(...c) { c.forEach((x) => this.set.delete(x)); },
      toggle(c, on) { if (on ?? !this.set.has(c)) this.set.add(c); else this.set.delete(c); },
      contains(c) { return this.set.has(c); },
    },
    get childNodes() { return el.children; },
    addEventListener(type, fn) { (el.listeners[type] ||= []).push(fn); },
    replaceChildren(...nodes) { el.children = nodes; },
    appendChild(node) { el.children.push(node); },
    getAttribute(name) { return el.attrs[name] ?? null; },
    setAttribute(name, v) { el.attrs[name] = String(v); },
    hasAttribute(name) { return name in el.attrs; },
    removeAttribute(name) { delete el.attrs[name]; },
  };
  return el;
}

/**
 * Runs `scripts` ([{ file, code }], in order) in one context with `ethers` and `CopraQuote` as globals.
 * Returns the context and an element accessor. quote.js and tailwind-config.js are not run: CopraQuote
 * is passed in, and the Tailwind config needs the CDN script.
 */
function runPage({ hostname = 'copra.dev', scripts, ethers, quote, console: con }) {
  const elements = new Map();
  const ctx = {
    console: con || { log() {}, warn() {}, error() {} },
    // Intervals run unref'd, so a page's polling never keeps a test process alive.
    setInterval: (fn, ms) => setInterval(fn, ms).unref(), clearInterval,
    setTimeout, clearTimeout, Promise, BigInt, Number, Math, Date, Object, Error, URL,
    window: { location: { hostname, search: '', origin: `https://${hostname}` } },
    navigator: {},
    document: {
      getElementById(id) {
        if (!elements.has(id)) elements.set(id, fakeElement(id));
        return elements.get(id);
      },
      createElement(tag) { return Object.assign(fakeElement(), { tagName: tag.toUpperCase() }); },
      querySelectorAll() { return []; },
    },
    ethers,
    CopraQuote: quote,
  };
  vm.createContext(ctx);
  for (const { file, code } of scripts) {
    if (file === 'quote.js' || file === 'tailwind-config.js') continue;
    vm.runInContext(code, ctx, { filename: file });
  }
  return { ctx, el: (id) => ctx.document.getElementById(id), elements };
}

/** The /assets/*.js files index.html loads, in order. */
const localScripts = (html) => [...html.matchAll(/<script\b[^>]*\bsrc="\/assets\/([^"]+)"/g)].map((m) => m[1]);

module.exports = { fakeElement, runPage, localScripts };
