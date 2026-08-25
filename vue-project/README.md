# vue-project

The preview UI of the macOS Markdown app. It is **not** shipped as files: `cargo build`
compiles this project and bakes `dist/` into the Rust `markdown_core` static library, which
serves it to a `WKWebView` over the `markdown-app://` URL scheme.

The app sends the document text down, Rust renders it to HTML, and this UI displays it —
see [`src/bridge/nativeBridge.ts`](src/bridge/nativeBridge.ts). Outside the web view
(`bun dev`) the bridge is unavailable and a plain source view is shown instead.

## Recommended IDE Setup

[VS Code](https://code.visualstudio.com/) + [Vue (Official)](https://marketplace.visualstudio.com/items?itemName=Vue.volar) (and disable Vetur).

## Recommended Browser Setup

- Chromium-based browsers (Chrome, Edge, Brave, etc.):
  - [Vue.js devtools](https://chromewebstore.google.com/detail/vuejs-devtools/nhdogjmejiglipccpnnnanhbledajbpd)
  - [Turn on Custom Object Formatter in Chrome DevTools](http://bit.ly/object-formatters)
- Firefox:
  - [Vue.js devtools](https://addons.mozilla.org/en-US/firefox/addon/vue-js-devtools/)
  - [Turn on Custom Object Formatter in Firefox DevTools](https://fxdx.dev/firefox-devtools-custom-object-formatters/)

## Type Support for `.vue` Imports in TS

TypeScript cannot handle type information for `.vue` imports by default, so we replace the `tsc` CLI with `vue-tsc` for type checking. In editors, we need [Volar](https://marketplace.visualstudio.com/items?itemName=Vue.volar) to make the TypeScript language service aware of `.vue` types.

## Customize configuration

See [Vite Configuration Reference](https://vite.dev/config/).

## Project Setup

```sh
bun install
```

### Compile and Hot-Reload for Development

```sh
bun dev
```

### Type-Check, Compile and Minify for Production

```sh
bun run build
```

Building the macOS app runs `bun run build-only` automatically through
`rust/markdown_core/build.rs`; run the command above when you want type checking too.
