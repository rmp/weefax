// <mode7-screen> - a teletext receiver for the mode7d carousel.
//
//   <mode7-screen page="100"></mode7-screen>
//
// Attributes: page (e.g. "101"), subpage (hold one subpage, e.g. "2"),
//             src (WebSocket URL; default ws(s)://<host>/ws),
//             height (px; default fits the element's width), font.
// Keys when focused: three digits select a page, Up/Down step through the
// index, R reveals concealed text, M toggles mix mode, Escape abandons entry.
// Events: mode7-page {page, subpage, subpages}, mode7-status {state}.
//
// The renderer attaches its own shadow root to this element via a document
// selector, so the element must live in the main document, not inside
// another component's shadow root.

import { Teletext } from 'https://cdn.jsdelivr.net/npm/@techandsoftware/teletext@1.3.1/dist/teletext.min.js';

const PAGE_RE = /^[1-8][0-9A-F]{2}$/i;
const ASPECT = 1.2; // the renderer's default width:height
let seq = 0;

class Mode7Screen extends HTMLElement {
  static observedAttributes = ['page', 'subpage', 'src', 'height', 'font'];

  #ttx = null;
  #ws = null;
  #retry = 0;
  #timer = null;
  #ro = null;
  #target = '100';
  #sub = null;
  #typed = '';
  #blink = null;
  #header = '';
  #shown = null; // "page/subpage" currently on screen
  pages = [];

  get page() { return this.#target; }
  set page(v) { this.setAttribute('page', String(v)); }

  connectedCallback() {
    if (!this.id) this.id = `mode7-screen-${++seq}`;
    if (!this.hasAttribute('tabindex')) this.tabIndex = 0;
    this.setAttribute('role', 'img');
    this.setAttribute('aria-label', 'Teletext screen');

    this.#ttx = Teletext();
    this.#ttx.addTo(`#${CSS.escape(this.id)}`);
    if (!this.shadowRoot.querySelector('style[data-mode7]')) {
      const style = document.createElement('style');
      style.dataset.mode7 = '';
      style.textContent = ':host{display:block;line-height:0;background:#000}' +
        ':host(:focus-visible){outline:2px solid #ff0;outline-offset:2px}' +
        'svg{display:block;max-width:100%;height:auto}';
      this.shadowRoot.prepend(style);
    }
    this.#ttx.setFont(this.getAttribute('font') || 'Bedstead, monospace');
    this.#size();
    this.#ro = new ResizeObserver(() => this.#size());
    this.#ro.observe(this);
    this.addEventListener('keydown', this.#onKey);
    this.#drawHeader('');
    this.#connect();
  }

  disconnectedCallback() {
    this.#ro?.disconnect();
    this.removeEventListener('keydown', this.#onKey);
    clearTimeout(this.#timer);
    clearInterval(this.#blink);
    const ws = this.#ws;
    this.#ws = null;
    ws?.close();
    this.#ttx?.remove();
    this.#ttx?.destroy();
    this.#ttx = null;
  }

  attributeChangedCallback(name, _old, value) {
    if (name === 'page') {
      if (!PAGE_RE.test(value ?? '')) return;
      this.#target = value.toUpperCase();
      this.#shown = null;
      this.#select();
      if (this.#ttx) this.#drawHeader(this.#header);
    } else if (name === 'subpage') {
      const n = parseInt(value, 10);
      this.#sub = Number.isInteger(n) && n > 0 ? n : null;
      this.#shown = null;
    } else if (!this.#ttx) {
      return;
    } else if (name === 'src') {
      this.#reconnect();
    } else if (name === 'height') {
      this.#size();
    } else if (name === 'font') {
      this.#ttx.setFont(value || 'Bedstead, monospace');
    }
  }

  reveal() { this.#ttx?.toggleReveal(); }
  mix() { this.#ttx?.toggleMixMode(); }

  #size() {
    if (!this.#ttx) return;
    const fixed = parseFloat(this.getAttribute('height'));
    const h = fixed > 0 ? fixed : Math.floor(this.clientWidth / ASPECT);
    if (h > 0) this.#ttx.setHeight(h);
  }

  #url() {
    const src = this.getAttribute('src');
    if (src) return src;
    return `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;
  }

  #connect() {
    const ws = new WebSocket(this.#url());
    this.#ws = ws;
    ws.onopen = () => {
      this.#retry = 0;
      this.#select();
      this.#status('searching');
    };
    ws.onmessage = (e) => {
      let m;
      try { m = JSON.parse(e.data); } catch { return; }
      if (m.t === 'pkt') this.#onPacket(m);
      else if (m.t === 'index') this.pages = m.pages ?? [];
    };
    ws.onclose = () => {
      if (this.#ws !== ws) return; // closed on purpose
      this.#status('offline');
      this.#drawHeader('\x01No signal');
      const delay = Math.min(10000, 500 * 2 ** this.#retry++);
      this.#timer = setTimeout(() => this.#connect(), delay);
    };
  }

  #reconnect() {
    clearTimeout(this.#timer);
    const ws = this.#ws;
    this.#ws = null;
    ws?.close();
    this.#connect();
  }

  #select() {
    if (this.#ws?.readyState === WebSocket.OPEN) {
      this.#ws.send(JSON.stringify({ t: 'select', pages: [this.#target] }));
    }
  }

  #onPacket(m) {
    this.#header = m.h;
    const hit = m.rows && m.p === this.#target && (this.#sub === null || this.#sub === m.s);
    if (!hit) {
      this.#drawHeader(m.h);
      return;
    }
    this.#ttx.setPageRows([this.#headerRow(m.h), ...m.rows]);
    const key = `${m.p}/${m.s}`;
    if (key !== this.#shown) {
      this.#shown = key;
      this.#status('found');
      this.dispatchEvent(new CustomEvent('mode7-page', {
        bubbles: true,
        detail: { page: m.p, subpage: m.s, subpages: m.n },
      }));
    }
  }

  #headerRow(h) {
    const cursor = Math.floor(Date.now() / 400) % 2 ? ' ' : '\x7f';
    const p = this.#typed ? (this.#typed + cursor).padEnd(3) : this.#target;
    return `P${p}`.padEnd(8, ' ') + (h ?? '');
  }

  #drawHeader(h) { this.#ttx?.setRow(0, this.#headerRow(h)); }

  #status(state) {
    this.dispatchEvent(new CustomEvent('mode7-status', { bubbles: true, detail: { state } }));
  }

  #onKey = (e) => {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    const k = e.key;
    if (/^[0-9]$/.test(k)) {
      if (!this.#typed && !/[1-8]/.test(k)) return;
      this.#typed += k;
      if (this.#typed.length === 3) {
        const p = this.#typed;
        this.#endEntry();
        this.removeAttribute('subpage');
        this.page = p;
      } else {
        this.#blink ??= setInterval(() => this.#drawHeader(this.#header), 100);
        this.#drawHeader(this.#header);
      }
    } else if (k === 'Escape' && this.#typed) {
      this.#endEntry();
      this.#drawHeader(this.#header);
    } else if (k === 'ArrowUp' || k === 'ArrowDown') {
      this.#step(k === 'ArrowUp' ? 1 : -1);
    } else if (k === 'r' || k === 'R') {
      this.reveal();
    } else if (k === 'm' || k === 'M') {
      this.mix();
    } else {
      return;
    }
    e.preventDefault();
  };

  #endEntry() {
    this.#typed = '';
    clearInterval(this.#blink);
    this.#blink = null;
  }

  #step(dir) {
    if (!this.pages.length) return;
    const t = parseInt(this.#target, 16);
    const nums = this.pages.map((p) => parseInt(p, 16));
    const next = dir > 0
      ? nums.find((n) => n > t) ?? nums[0]
      : [...nums].reverse().find((n) => n < t) ?? nums[nums.length - 1];
    this.removeAttribute('subpage');
    this.page = next.toString(16).toUpperCase();
  }
}

customElements.define('mode7-screen', Mode7Screen);
export { Mode7Screen };
