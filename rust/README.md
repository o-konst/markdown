# markdown_core

Rust backend of the macOS Markdown app. It does two things:

1. **Carries the web UI.** `build.rs` builds `../../vue-project` with Vite and turns every
   file of `dist/` into an `include_bytes!` entry, so the whole Vue app lives inside
   `libmarkdown_core.a`. Nothing is loaded from disk or the network at runtime.
2. **Renders Markdown** to HTML with `pulldown-cmark`.

Both are exposed over the C ABI declared in
[`include/markdown_core.h`](markdown_core/include/markdown_core.h).

## How the app uses it

```
TextEditor ──text──▶ WebPreviewCoordinator ──md_render()──▶ Rust ──HTML──▶ Vue app
                              ▲                                              │
                              └──── markdown-app:// asset request ───────────┘
                                        (md_asset_lookup)
```

* `Markdown/MarkdownCore.swift` wraps the C API.
* `Markdown/MarkdownWebView.swift` hosts the `WKWebView`, answers `markdown-app://`
  requests from the embedded assets, and bridges `connect`/`render` calls from JavaScript.
* The Xcode target runs [`build-xcode.sh`](build-xcode.sh) in its "Build Rust core" phase,
  which builds a slice per architecture in `ARCHS` and merges them with `lipo` into
  `target/apple/$PLATFORM_NAME-$CONFIGURATION/libmarkdown_core.a`.

## Working on it

```sh
cargo test                     # renderer + asset lookup + FFI
./build-xcode.sh               # Debug slice for the host machine
MARKDOWN_SKIP_UI_BUILD=1 cargo build   # reuse the existing vue-project/dist
```

Because the Xcode run script shells out to `cargo` and `bun`, the app target sets
`ENABLE_USER_SCRIPT_SANDBOXING = NO`. The sandboxed app also needs
`com.apple.security.network.client` (`ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`) — without
it WebKit's helper processes crash on launch, even though the app never touches the network.
