# Vue frontend reference (`vue-project/`)

This Vue 3 + TypeScript + Vite app is **not a standalone web app** — its production build
(`dist/`) is embedded as raw bytes directly into the Rust `markdown_core` crate at compile
time (`build.rs`) and served to a native WebView (`WKWebView` on macOS via a
`markdown-app://` custom scheme, WebView2 on Windows via a fake `https://markdown-app.local`
origin). It renders the markdown preview HTML that Rust produces and communicates with the
native host over a JS↔native bridge.

## 1. App overview

- **Entry point** (`main.ts`): trivial — imports global CSS, mounts `App.vue` at `#app`.
  No router, no state library (Pinia/Vuex absent).
- **`App.vue`**: the whole application shell. A two-pane layout — a resizable outline
  sidebar (`DocumentOutline.vue`) and a scrollable content pane (`MarkdownPreview.vue`).
  **This is a preview + outline pane, not an editor** — there is no text
  input/textarea anywhere; markdown source arrives from the native host and only rendered
  HTML is displayed.
- Wires together `useMarkdownPreview()` (doc/HTML/preferences state),
  `useDocumentOutline(html)` (derives the heading tree + re-IDs headings), and
  `useActiveHeading(scroller, ids)` (scroll-spy). Calls `reportOutlineState()` back to the
  host whenever `hasOutline` changes.
- Owns UI-only state directly (no composable): a pointer-drag resizable splitter between
  panes, persisted to `localStorage` under `markdown.outlineWidth` (clamped 160–448px,
  default 240, wrapped in try/catch since storage "is unavailable on some hosts and throws
  rather than returning null"). `preferences.contentWidth === 'page'` caps the content
  pane at `72ch`; `preferences.fontSize` is applied as inline `font-size` on the scroller.

## 2. Native bridge (`src/bridge/nativeBridge.ts`)

Communicates over **`WKScriptMessageHandlerWithReply`** only — i.e., **WKWebView-only**.
Handler name is `HANDLER_NAME = 'markdownBridge'`. **No WebView2-specific code path
exists** anywhere in this file or the rest of `src/` (no `chrome.webview` references).

- `messageHandler()` returns `window.webkit?.messageHandlers?.['markdownBridge']`.
- `isNativeHost(): boolean` — true iff that handler exists. This is the **sole** feature
  detection gate; there's no WebView2 detection here.
- `send<T>(request: HostRequest): Promise<T>` — internal helper; throws `'Native bridge
  unavailable'` if no handler.

**Outbound (JS → host)**, `HostRequest` union:

- `{ method: 'connect' }` → `connect(): Promise<HostInfo>` — handshake announcing the UI
  is mounted.
- `{ method: 'render', markdown: string }` → `render(markdown): Promise<string>` — asks
  the host for rendered HTML.
- `{ method: 'outlineState', available: boolean }` → `reportOutlineState(available):
  Promise<void>` — swallows errors from hosts that don't implement it, and short-circuits
  entirely when not native.

`HostInfo` (reply to `connect`): `{ coreVersion: string, assetCount: number, text: string,
preferences?: unknown }`. `preferences` is explicitly documented as absent on hosts
without a settings window, "**including the Windows app**" — direct evidence from the
Vue source that the C# host doesn't send preferences, consistent with `windows-app.md`.

**Inbound (host → JS)** — not sent as replies, but via a **global object the host writes
to directly**: `window.__markdownHost: MarkdownHost` with optional `setDocument(text)` and
`setPreferences(preferences)`. The JS side doesn't listen for a `postMessage` event for
these — instead, `onDocumentChange(listener)` / `onPreferencesChange(listener)`
**monkey-patch** `window.__markdownHost.setDocument`/`.setPreferences`, chaining to any
previously-installed handler so multiple subscribers can coexist, returning an unsubscribe
that only restores the previous handler if it's still the top of the chain. **This means
transport is asymmetric**: JS→native is `postMessage` + reply; native→JS is a direct
global-object function call (e.g. via `evaluateJavaScript:` on macOS, `ExecuteScriptAsync`
on Windows). A new bidirectional feature must respect this asymmetry — a new "push" needs
to extend `MarkdownHost` and be invoked as a plain JS call from native code, not sent as a
reply to a pending promise.

`normalizePreferences(raw: unknown): Partial<WebPreferences>` whitelists/clamps every
field (`outlineVisible` boolean; `contentWidth` must be one of `['full','page']`;
`fontSize` clamped 11–24) so "a host on a different version cannot put the UI into a
nonsense state."

**No `markdown-app://` asset-request handling appears anywhere in this JS** — that flow is
entirely native-side; the web content just loads ordinary relative URLs
(`/src/main.ts`, `/favicon.ico`, etc.) that the WebView intercepts transparently.

**Dev/standalone fallback**: `renderFallback(markdown: string): string` — HTML-escapes
the raw markdown and wraps it in `<pre class="raw-source">`; explicitly "Deliberately
dumb: real rendering is the Rust library's job."

## 3. Composables

- **`useMarkdownPreview()`**: owns `html`, `source`, `status: BridgeStatus`
  (`'connecting'|'connected'|'standalone'|'error'`), `coreVersion`, `assetCount`,
  `error`, `preferences` — all returned as `readonly()` refs, plus a mutable
  `update(text: string)`. On mount: subscribes via `onDocumentChange`/
  `onPreferencesChange`; if `!isNativeHost()`, sets `status='standalone'` and renders a
  hardcoded sample document via `renderFallback`; otherwise calls `connect()` and seeds
  state from the handshake reply — but only seeds document text if the host hasn't
  already pushed a newer one while `connect()` was in flight (a documented race guard).
  `update()` also guards against **out-of-order replies** with a monotonic
  `latestRequest` counter, dropping stale `render()` responses — necessary because
  `render()` presumably fires on every keystroke from the host.
- **`useDocumentOutline(html)`**: pure derivation via `computed`, no bridge calls. Parses
  the HTML fragment with `DOMParser`, walks `h1`–`h6`, builds a nested `OutlineNode[]`
  tree using an ancestor-stack algorithm that correctly handles skipped heading levels
  (h1→h3). Slugs headings lacking an `id` (Rust's renderer only assigns ids to
  `{#custom-id}`-tagged headings) via `slugify()` (lowercase, NFKD-normalize,
  non-letter/digit runs → `-`), de-duplicating collisions with a numeric suffix. **This
  slug rule is mirrored byte-for-byte in Rust's `markdown_vault::outline::slugify` — keep
  both in lockstep**, or search-result anchors and preview anchors will silently diverge
  (see `rust-core.md` §3.4). Returns `{ html, nodes, ids, hasOutline }` where `html` is
  the *mutated* fragment (headings now carry ids) and `hasOutline = ids.length >= 2`.
- **`useActiveHeading(scroller, ids)`**: scroll-spy returning a single
  `activeId: Ref<string|null>`. Explicitly avoids `IntersectionObserver` because "the
  preview is re-rendered on every keystroke ... which replaces every heading element" —
  uses a `requestAnimationFrame`-throttled scroll listener that re-queries via
  `querySelector` each time. `ACTIVATION_OFFSET = 96px` from the scroller's top edge
  defines "current."

## 4. Components

- **`MarkdownPreview.vue`**: props `html: string`, `isEmpty: boolean`. **`v-html="html"`
  is still used** at line 12, with the comment "Trusted content: produced by the Rust
  renderer from the user's own document." **No client-side sanitization exists** (no
  DOMPurify or similar anywhere in `package.json` or `src/**`). This is safe in practice
  today **because Rust's `render.rs` now sanitizes with `ammonia` before HTML ever
  reaches this component** (see `security.md`) — but there is exactly one layer of
  defense, entirely on the Rust side, with nothing at this sink as a backstop. No emits.
- **`DocumentOutline.vue`**: props `nodes: OutlineNode[]`, `activeId: string | null`;
  emits `select: [id: string]`. A `<nav>` wrapper with a "Contents" label around
  `OutlineList`.
- **`OutlineList.vue`**: same props/emits shape; renders one `<li>` per node with an
  anchor (`href="#id"`, click prevented and re-emitted as `select`) and **recurses into
  itself** for `node.children` (a self-referencing SFC).

## 5. Build configuration

- **`vite.config.ts`**: plugins are `@vitejs/plugin-vue`, `vueJsx`,
  `vite-plugin-vue-devtools`; one alias `@` → `./src`. **No `base` option is set**
  (defaults to `/`), and `index.html` references absolute-rooted paths
  (`/favicon.ico`, `/src/main.ts`). Since the whole `dist/` tree is embedded into the Rust
  binary and served over the native custom-scheme handler, that handler resolves these
  root-relative asset paths against the embedded asset map — invisible from the JS side,
  consistent with the finding in §2 that no scheme-handling logic exists in the frontend
  itself.
- **TypeScript**: standard Vue 3 split-config (`tsconfig.json` referencing
  `tsconfig.app.json` + `tsconfig.node.json`), `@vue/tsconfig/tsconfig.dom.json` base,
  `noUncheckedIndexedAccess: true`, path alias mirroring Vite's.
- **`package.json`**: single runtime dependency, `vue@^3.5.40`. No router, no state
  library, no HTTP client, no markdown library (rendering is entirely delegated to Rust),
  no sanitization library, and **no test runner configured** — no vitest/cypress config
  exists despite `tsconfig.node.json` referencing test-tooling types generically.
- **Dev vs. embedded mode**: the *only* branch point is `isNativeHost()` — `vite dev` in a
  plain browser has no `window.webkit`, so the app runs in `'standalone'` status, showing
  a static sample document rendered through `renderFallback`'s escaped-`<pre>` path.
  There's no mock/stub bridge server beyond this fallback, so interactive testing of real
  markdown rendering, outline behavior, or preferences syncing is **not possible** in
  plain browser dev mode — only the static sample can be seen.

## 6. Chat panel

**Does not exist.** No file matching `*Chat*` anywhere under `vue-project/src/`. The
design plan's `ChatPanel.vue` and `appendChatEvent` bridge message are planned/future work
only — confirmed absent, not just unfinished.

## 7. Gotchas / flags for future contributors

1. **WebView2 support gap**: `nativeBridge.ts` detects the native host solely via
   `window.webkit.messageHandlers`, which is WKWebView-only. The Windows shell's
   `MarkdownWebView.xaml.cs` (see `windows-app.md` §3) works around this by *injecting a
   `window.webkit`-shaped polyfill* before any page script runs — so from this file's
   perspective, Windows looks native too. Any change to the detection logic here must stay
   compatible with that Windows-side shim.
2. **Unsanitized `v-html` has exactly one line of defense**: the design plan's original
   XSS finding (raw HTML/`onerror=`/`javascript:` URLs surviving into `v-html`) is fixed
   at the Rust layer (`render.rs` + `ammonia`), but nothing has been added here as a
   second line of defense. If `render.rs` sanitization is ever weakened or bypassed (e.g.
   a new render path that skips it), this component has no independent protection.
3. **Asymmetric transport** (§2) — a new bidirectional bridge feature is easy to implement
   backwards; remember JS→native uses `postMessage`+reply, native→JS uses a direct global
   call.
4. **No automated tests** exist for any composable despite meaningful edge-case logic
   (skipped heading levels, slug collisions, out-of-order render replies) that would
   benefit from unit coverage.
