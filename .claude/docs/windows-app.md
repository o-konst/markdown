# Windows app reference (`win/MarkdownWin/`)

A WinUI 3 (C#) desktop app. This is a **minimal single-document editor + preview shell**
— pre-dating the entire vault/agent/chat initiative described in the design plan. Per the
plan's own framing: **"Windows gets everything except the shell."** Read this doc
alongside `macos-app.md` for the gap list — most of what exists on macOS today has no
Windows counterpart yet.

## 1. Architecture overview

Three collaborator types:

- **`App`** (`App.xaml`/`App.xaml.cs`) — `Application` subclass. `OnLaunched` creates a
  single `MainWindow` and activates it. No suspend/resume handling, no multi-window
  support, no dependency injection, no exception handlers registered.
- **`MainWindow`** (`MainWindow.xaml`/`.xaml.cs`) — the whole UI: a `CommandBar`
  (New/Open/Save/Save As, each with a keyboard accelerator) over a two-pane `Grid` — a
  `TextBox` named `Editor` on the left, a divider, and a `local:MarkdownWebView` named
  `Preview` on the right. Owns one `MarkdownDocument` field. Wires
  `Editor.TextChanged` → `document.Text = Editor.Text` → `Preview.SetDocumentText(document.Text)`.
  `AttachDocument` re-subscribes to `PropertyChanged` and re-syncs editor text and preview
  whenever a new/opened document replaces the current one. Window title is driven off
  `document.Title` via a `PropertyChanged` listener.
- **`MarkdownDocument`** (`MarkdownDocument.cs`) — plain `INotifyPropertyChanged` model:
  `Text` (defaults to `"Hello, world!"`), optional `Path` (`null` = new/untitled),
  `IsModified`, and a computed `Title` (`"{name} •"` when dirty, `"Untitled"` when `Path`
  is null). `LoadAsync`/`SaveAsync` do direct UTF-8 file I/O (`Encoding.UTF8` /
  `UTF8Encoding(encoderShouldEmitUTF8Identifier: false)` — explicitly no BOM on save). No
  debouncing, autosave, or dirty-buffer protection against external changes.
- **`MarkdownCore`** (`MarkdownCore.cs`, `internal static`) — the FFI facade, used only by
  `MarkdownWebView`. Rendering happens JS-side in the preview, not from `MainWindow`
  directly.

Data flow: `Editor` (user types) → `MarkdownDocument.Text` →
`MarkdownWebView.SetDocumentText` → JS bridge push → Vue app calls back into
`MarkdownCore.Render` (via the bridge's `render` method) — entirely inside the
WebView2/JS layer. C# app code itself never calls `MarkdownCore.Render` directly.

## 2. Rust FFI boundary (`MarkdownCore.cs`)

P/Invokes against `markdown_core` (`DllImport("markdown_core", CallingConvention.Cdecl)`):

- `IntPtr md_version()`
- `nuint md_asset_count()`
- `IntPtr md_render(string markdown)` (`LPUTF8Str` marshaling)
- `void md_string_free(IntPtr value)`
- `bool md_asset_lookup(string path, out MdAsset asset)` — `MdAsset` is a sequential
  struct `{ IntPtr Data; nuint Len; IntPtr Mime; }`

**Only these 4 render/asset functions exist.** There are **no `vault_*` or `agent_*`
P/Invoke declarations anywhere in the C# project** — confirmed by reading the whole
surface. `markdown_core`'s C ABI includes `md_vault_*` and `md_agent_*` functions (see
`rust-core.md` §2.3), but `MarkdownCore.cs` hasn't been extended to cover them.

Library loading is implicit through standard .NET P/Invoke resolution (next to the
executable, then system paths) — no explicit `NativeLibrary.Load` call.
`IsAvailable` calls `md_asset_count()` once and catches
`DllNotFoundException`/`EntryPointNotFoundException` to memoize a bool; every public
method short-circuits to an empty/null value when unavailable, so a missing DLL degrades
gracefully (`MarkdownWebView` shows a fallback `TextBlock` instead of the WebView2).

Marshaling detail: `Render` always frees the native string via `md_string_free` in a
`finally` (no leak). `Asset` copies the byte buffer via `Marshal.Copy` into a managed
`byte[]` — no explicit free call is made for the `MdAsset.Data`/`Mime` pointers, so
whether that memory needs freeing depends on Rust's ownership contract (likely
borrowed/`'static`, given the embedded-asset design — worth confirming against
`markdown_core.h` before adding any dynamic, non-embedded asset source).

## 3. WebView hosting (`MarkdownWebView`)

Uses **`Microsoft.Web.WebView2.Core`** (`Microsoft.UI.Xaml.Controls.WebView2`, named
`WebView`). Key mechanics:

- **Custom origin, not custom scheme**: rather than registering a custom URI scheme (as
  macOS's literal `markdown-app://` does), it navigates to a fake HTTPS origin
  `https://markdown-app.local/index.html` and intercepts everything via
  `CoreWebView2.AddWebResourceRequestedFilter("https://markdown-app.local/*", ...)` +
  `WebResourceRequested`. The handler takes the request's `AbsolutePath`, calls
  `MarkdownCore.Asset(path)`, and returns a `CoreWebView2WebResourceResponse` (200 + the
  bytes, or 404 if `null`). Same embedded-asset bytes as macOS, different transport
  convention appropriate to WebView2.
- **JS↔native bridge**: an injected `BridgeScript` (via
  `AddScriptToExecuteOnDocumentCreatedAsync`, so it runs before any page script)
  **reimplements `window.webkit.messageHandlers.markdownBridge.postMessage`** as a
  promise-returning shim over `chrome.webview.postMessage` — explicitly so the *same* Vue
  bundle (written against WebKit's message-handler API for macOS) runs unmodified on
  Windows. Replies flow back via `window.__markdownBridgeReply(id, result, error)`,
  invoked from C# through `ExecuteScriptAsync`.
- **Bridge methods handled** (`OnWebMessageReceived`, dispatched on a `method` string):
  `"connect"` (returns `{coreVersion, assetCount, text}`), `"render"` (returns
  `MarkdownCore.Render(markdown)` — this is where Rust rendering actually gets invoked,
  from JS), `"outlineState"` (accepted but ignored — "this host has no toggle to
  update"); unknown/null methods reply with an error string.
- **Document push**: `SetDocumentText` diffs against a cached `text` field and calls
  `PushDocumentAsync`, which retries injecting `window.__markdownHostPush(text)` up to 100
  times at 100ms intervals until the Vue app has mounted and installed its listener — a
  polling handshake rather than event-based, needed because the WebView's own page-load
  timing and Vue's mount timing aren't otherwise synchronized.
- **Navigation containment**: `OnNavigationStarting` cancels any navigation whose host
  isn't `markdown-app.local` and instead calls `Launcher.LaunchUriAsync` (opens
  externally) — same for `OnNewWindowRequested`. Context menus are disabled.

## 4. `MarkdownDocument`

The C# structural counterpart to (per its own doc comment) the plan's document model, but
it is **not** the vault-backed model described in the design plan (`VaultStore`,
journaled writes, autosave) — it's a bare file-picker-driven load/save object with no
relationship to any "vault" concept, no autosave, and no external change detection.
`Text`'s setter marks `IsModified = true` on any change (including programmatic resets
from `LoadAsync`, though `LoadAsync` sets the private backing field directly, not through
the property, so loading a file doesn't spuriously mark it dirty).

## 5. App lifecycle & packaging

- **`App.xaml.cs`**: minimal, single-window only.
- **`app.manifest`**: declares Windows 10 OS-feature compatibility (needed for the custom
  title bar / unpackaged-app features) and per-monitor-v2 DPI awareness.
- **`Package.appxmanifest`**: identity is a raw GUID name with publisher `CN=konstantin` —
  a dev/unsigned identity, not Store-ready. `TargetDeviceFamily` spans
  `Windows.Universal`/`Windows.Desktop`, min version `10.0.17763.0` (Windows 10 1809),
  tested up to `10.0.26226.0`. **Capabilities**: `runFullTrust` (required for
  unpackaged/full-trust WinUI 3 desktop apps) and, notably,
  **`systemai:Capability Name="systemAIModels"`** — a Windows System AI Models capability
  declaration. This is the one concrete signal of AI-feature intent on Windows, but **no
  code anywhere in this project currently uses it** — no chat UI, no `AgentClient`
  equivalent, no credential-manager access. No explicit network/broad filesystem
  capabilities are declared (`runFullTrust` implies broad access without itemized
  capabilities).

## 6. Project/solution structure

- **`MarkdownWin.slnx`** (XML-based solution format): single project, three platform
  configs — `ARM64`, `x64`, `x86`.
- **`MarkdownWin.csproj`**: `TargetFramework=net8.0-windows10.0.19041.0`,
  `TargetPlatformMinVersion=10.0.17763.0`, `UseWinUI=true`, `EnableMsixTooling=true`,
  `Nullable=enable`. Packages: `Microsoft.Windows.SDK.BuildTools 10.0.28000.2526`,
  `Microsoft.WindowsAppSDK 2.4.0`. Publish profiles exist for `win-x64`, `win-x86`,
  `win-arm64`.
- **Rust integration is orchestrated entirely from MSBuild**, not checked-in binaries:
  - A `BuildMarkdownCore` target (`BeforeTargets="BeforeBuild"`) shells out to
    `cargo build --target <triple> [--release]` in `rust/markdown_core`, mapping
    `$(Platform)` (`x64`/`x86`/`ARM64`) to the matching `*-pc-windows-msvc` triple, with
    `CARGO_TARGET_DIR` and `MARKDOWN_SKIP_UI_BUILD=1` set. It's `ContinueOnError="true"`
    with a `Warning` on failure, so a missing Rust toolchain degrades to a stale/absent
    DLL rather than failing the C# build.
  - `MARKDOWN_SKIP_UI_BUILD=1` is set unconditionally: per an inline comment, the Vue UI
    is only ever built on macOS (its `node_modules` uses POSIX symlinks that break over
    this team's SMB/network share); Windows always reuses whatever `vue-project/dist`
    already exists rather than building the frontend itself.
  - `CopyMarkdownCore` copies the resulting `markdown_core.dll` next to the app output.
  - Two network-drive workarounds baked into the csproj: `BaseOutputPath` is forced to
    `%LOCALAPPDATA%\MarkdownWin\build\bin\` (MSIX can't register from a network path —
    `DEP0700`), and Cargo's target dir is forced to
    `%LOCALAPPDATA%\MarkdownWin\rust-target` (Cargo can't manage temp archives on this
    team's `W:` network drive — `os error 87`). **Both indicate active development happens
    with the repo checked out on a network share** — a contributor working from a local
    drive who "fixes" these paths without understanding why could reintroduce the original
    failures for everyone else.

## 7. Gap analysis vs. macOS / the design plan

**Present on Windows**: markdown editing (plain `TextBox`, no syntax highlighting), file
open/save via native pickers, live HTML preview via the shared Rust renderer + shared Vue
bundle, external-link containment.

**Absent on Windows** (all exist as `.swift` files on macOS):

- No sidebar / folder tree / multi-file vault browsing (`FileNode`, `Workspace`,
  `SidebarView` equivalents) — Windows is single-document, no notion of a vault folder.
- No AI chat panel or agent-loop client (`ChatView`, `ChatViewModel`, `AgentClient`
  equivalents) — despite the `systemAIModels` manifest capability.
- No authentication/login or credential storage (`LoginView`, `Account`, `Keychain`
  equivalents) — no Windows Credential Manager usage anywhere.
- No folder watcher / live external-change reload (`VaultWatcher` equivalent).
- No vault read/write facade (`VaultStore.cs` doesn't exist) — and correspondingly no
  `vault_*` FFI calls, confirmed in §2.
- No search (`FolderSearch` equivalent).
- No settings UI (`SettingsView` equivalent).
- No autosave/debounce — save is fully manual (Ctrl+S / Save button), unlike the
  "debounced autosave plus flush on file switch and quit" the design plan requires before
  any write-capable feature ships.

## 8. Gotchas / TODOs

- **`systemAIModels` capability is declared but unused** — confirm with whoever added it
  whether it's aspirational or a leftover before relying on it.
- **`.NET upgrade is staged, not applied.`** `.github/upgrades/scenarios/dotnet-version-upgrade/`
  contains only an *assessment* (target `net8.0-windows10.0.19041.0` →
  `net10.0-windows10.0.22000.0`, "All-at-Once" strategy, "Fix Inline" for unsupported
  APIs) plus generated `assessment.csv`/`.json`/`.md`, `scenario.json`,
  `scenario-instructions.md`, `upgrade-options.md`. **No upgrade has actually been
  performed** — the live `.csproj` still targets `net8.0-windows10.0.19041.0`. 20 flagged
  issues across 6 files, dominated by `System.Uri` behavioral changes (8 occurrences),
  low overall difficulty (~19 LOC, 2.1% of an 894-line codebase). The scenario notes
  explicitly "Not a git repository — no source control automation applies," consistent
  with this whole repo not being a git repo. Also note: some analysis tooling
  mislabeled the project as "WinForms" — it's unambiguously WinUI 3
  (`UseWinUI=true` + XAML files); don't take that label at face value.
- **Network-share development friction** (§6) — the `BaseOutputPath`/`CARGO_TARGET_DIR`
  overrides only make sense given the repo's checked-out-on-SMB setup.
- **Two stray files**: `MarkdownWin.csproj.Backup.tmp` and `MarkdownWin.csproj.user` sit
  alongside the real `.csproj` — the former looks like a leftover that should probably be
  removed (not verified whether it's tracked anywhere, since this isn't a git repo).
- **`MdAsset` pointer lifetime unconfirmed** (§2) — `Asset()` never frees
  `MdAsset.Data`/`Mime`; confirm against `markdown_core.h` whether these are meant to be
  `'static` before adding any non-embedded asset source.
- **Bridge method surface is intentionally minimal** (`connect`, `render`,
  `outlineState` only) — if the shared Vue app's bridge contract grows (e.g. for vault
  operations once the MCP/vault work lands on Windows), this switch statement in
  `MarkdownWebView.xaml.cs` is the one place needing a matching case, mirroring whatever
  `MarkdownWebView.swift` implements.
