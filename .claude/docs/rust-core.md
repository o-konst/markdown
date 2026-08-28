# Rust core reference (`rust/`)

The Rust workspace is the center of gravity of this project: rendering, asset embedding,
vault storage/security, and the AI agent loop all live here, exposed to Swift and C#
through one C ABI.

## 1. Workspace layout

```
rust/                          [workspace] resolver="2"
                                release profile: lto=true, codegen-units=1, strip=debuginfo
  markdown_core/                lib: staticlib + cdylib + rlib — the only crate the apps link
  markdown_vault/                lib: confinement, storage, git history, search, outline, tool dispatch
  markdown_agent/                lib: Claude/Anthropic agent loop
  vendor/solomd-mcp/             bin: vendored fork of an upstream MCP server (see §1a)
```

Dependency direction:

```
markdown_core ──depends on──▶ markdown_agent ──depends on──▶ markdown_vault
      │                                                             ▲
      └──────────────────────depends on────────────────────────────┘
```

- `markdown_core` depends on both `markdown_agent` and `markdown_vault` (path deps), plus
  `ammonia`, `pulldown-cmark`, `serde_json`.
- `markdown_agent` depends on `markdown_vault` + `reqwest` (blocking, rustls-tls, no
  default features), `serde`/`serde_json`.
- `markdown_vault` depends on `git2` (default-features off, so it links a system/library
  libgit2 rather than a vendored one), `serde`, `unicode-normalization`. It has **no**
  dependency on the other two crates — it's the bottom of the stack; nothing above it is
  allowed to touch the filesystem directly except through it.

Crate types: `markdown_core` is `["staticlib", "cdylib", "rlib"]` — staticlib for the
macOS app (linked into the Xcode target as `libmarkdown_core.a`), cdylib for the Windows
app (loaded as `markdown_core.dll`), rlib so it can be used as an ordinary dependency in
its own tests. `markdown_vault` and `markdown_agent` are plain rlibs — Swift/C# never link
them directly, only through `markdown_core`'s FFI shim.

### 1a. `vendor/solomd-mcp` — vendored, not aspirational

The design plan (`.claude/plans/ai-assistant-mcp-and-chat.md`) floated `solomd-mcp` as
possible prior art worth "pointing at the vault" instead of building a new MCP crate. That
decision has since been made: **`solomd-mcp` is vendored in as a workspace member**
(`PROVENANCE.md` inside it records it was copied 2026-08-24 from upstream `solomd-mcp`
v0.4.1, MIT-licensed). It is a real, standalone binary crate (`rmcp` 1.5, stdio +
Streamable HTTP transports, `--allow-write` gate, workspace federation), built via
`build-xcode.sh` and copied into the macOS app bundle's `Contents/MacOS/` (code-signed) so
the app ships its own MCP sidecar without requiring a separate install.

**It does not reuse `markdown_vault`.** Per its own `PROVENANCE.md`, `solomd-mcp` carries
its own `safety.rs` (path confinement) and `workspace.rs` (walking/search/history) —
completely independent of `markdown_vault`'s `confine.rs`/`search.rs`/`history.rs`. **Two
independently-implemented security boundaries exist in this repository right now.** The
provenance doc names the intended convergence explicitly: keep `solomd-mcp`'s `main.rs`
(CLI/transport/gate/federation) but repoint its tool bodies at
`markdown_vault::tools::call`, then delete its `safety.rs`/`workspace.rs`. **That
convergence has not happened yet** — see `security.md`.

Four tools were stripped when vendoring (`share_url`, `sync_status`, `export_note`,
`read_agent_trace` — all called SoloMD's own hosted services), leaving 11 tools upstream.
`git2` was bumped 0.19→0.21 to match `markdown_vault`'s version — a hard workspace
constraint, since `libgit2-sys` declares `links = "git2"` and only one version can exist
across the whole workspace. Note `solomd-mcp` uses the `vendored-libgit2` feature while
`markdown_vault` does not; this mixed-feature situation across one `links` key is worth
re-verifying still builds cleanly if either crate's `git2` dependency changes.

The MCP server is currently **macOS-only** in the build pipeline (`build-xcode.sh` only
builds/bundles it when `PLATFORM_NAME=macosx`); there is no Windows packaging for it.

## 2. `markdown_core` — rendering, assets, and the C ABI

### 2.1 Rendering pipeline (`render.rs`)

`render_markdown(markdown: &str) -> String` is the single entry point:

```
pulldown_cmark::Parser (TABLES | FOOTNOTES | STRIKETHROUGH | TASKLISTS
                          | SMART_PUNCTUATION | HEADING_ATTRIBUTES)
  → pulldown_cmark::html::push_html
  → ammonia::Builder sanitize (lazily-initialized, process-wide OnceLock<Builder>)
```

**The XSS finding from the design plan is fixed.** The plan flagged that `render.rs` set
no HTML-filtering option, so raw HTML (`<img src=x onerror=…>`) would pass straight
through to the Vue preview's `v-html`. The current code sanitizes with an allow-list
`ammonia::Builder`, widened only for what the renderer itself emits: generic `id`/`class`
attributes (for `{#custom-id}` heading anchors and footnote markers/syntax highlighting)
and `<input type/checked/disabled>` (disabled task-list checkboxes). Everything else —
`<script>`, `onerror=`, `javascript:` URLs — is stripped by ammonia's default allow-list.
Ten tests cover this directly (`strips_script_tags`, `strips_event_handler_attributes`,
`strips_javascript_urls`, `strips_inline_event_handlers_in_raw_html`, plus positive tests
confirming legitimate content — headings, custom anchors, task lists, tables, footnotes,
images, code — survives intact). **This is a hard security invariant**: any future change
to `render.rs` should re-run these tests before merging.

### 2.2 Asset embedding (`assets.rs` + `build.rs`)

`build.rs` runs at `markdown_core` compile time:

1. Locates `../../vue-project`.
2. Unless `MARKDOWN_SKIP_UI_BUILD=1` is set, runs `bun install --frozen-lockfile` (falling
   back to `npm install`) then `bun run build-only` / `npm run build-only` (this skips
   `vue-tsc` type-checking — that stays a separate, manual step).
3. Verifies `dist/index.html` exists.
4. Walks `dist/` and generates `$OUT_DIR/web_assets.rs` — one `WebAsset { path, mime,
   bytes: include_bytes!(...) }` per file, sorted by path in a `BTreeMap`.
5. `assets.rs` pulls this in via `include!(concat!(env!("OUT_DIR"), "/web_assets.rs"))` as
   `WEB_ASSETS` — the whole Vue `dist/` tree becomes part of the compiled binary. Nothing
   is loaded from disk or network at runtime.

`MARKDOWN_SKIP_UI_BUILD=1` skips the `bun`/`npm` step entirely and reuses whatever is
already in `vue-project/dist` — the fast inner loop for Rust-only changes. Windows-specific
handling in `build.rs`: `npm`/`bun` are `.cmd` shims that `Command::new` can't resolve
directly, so they're launched via `cmd /C`, with a `pushd`-based UNC-path workaround since
`cmd` can't use a UNC path as its working directory.

Runtime lookup, `assets::lookup(request_path)`: normalizes the path (strips
query/fragment, trims slashes, filters `.`/`..` segments), tries an exact match, then
`{path}/index.html`, then falls back to `index.html` — SPA-fallback behavior so
client-side routes resolve correctly inside the WebView. `assets::exact()` is the same
without the SPA fallback (used to assert unknown paths 404 in tests). MIME types are
inferred by extension in `build.rs`'s `mime_for()` and baked in as NUL-terminated strings
so they can be handed to C without extra allocation (`WebAsset::mime_ptr()`).

### 2.3 Full C ABI surface

All three FFI modules (`ffi.rs`, `agent_ffi.rs`, `vault_ffi.rs`) are public modules of
`markdown_core`, mirrored exactly in `include/markdown_core.h`. Every fallible/unsafe entry
point wraps its body in `catch_unwind(AssertUnwindSafe(...))` so a Rust panic can never
unwind across the FFI boundary (undefined behavior otherwise) — it converts to a
`NULL`/`false`/error-JSON return instead.

| Function | Signature | Module | Purpose |
|---|---|---|---|
| `md_asset_lookup` | `bool(const char *path, MdAsset *out)` | ffi.rs | Look up one embedded Vue asset by URL path (SPA-fallback to `index.html`); zeroes `out` and returns `false` on failure |
| `md_asset_count` | `size_t(void)` | ffi.rs | Count of embedded files (startup diagnostics) |
| `md_render` | `char *(const char *markdown)` | ffi.rs | Render + sanitize Markdown → owned UTF-8 HTML string; `NULL` on invalid UTF-8 input |
| `md_version` | `const char *(void)` | ffi.rs | Static version string (`CARGO_PKG_VERSION`); do not free |
| `md_string_free` | `void(char *value)` | ffi.rs | Frees any string returned by `md_render`/`md_vault_call`/`md_vault_tools`; NULL-safe |
| `md_vault_open` | `MdVault *(const char *path)` | vault_ffi.rs | Opens/adopts a vault at `path`, initializing git history + a baseline commit if new; `NULL` if unusable |
| `md_vault_close` | `void(MdVault *vault)` | vault_ffi.rs | Closes a vault handle; NULL-safe |
| `md_vault_call` | `char *(MdVault *vault, const char *name, const char *input_json)` | vault_ffi.rs | Dispatches one named tool with JSON args; always returns `{"ok":true,"result":...}` or `{"ok":false,"error":...}`; `NULL` only on unusable pointers/JSON |
| `md_vault_tools` | `char *(void)` | vault_ffi.rs | Full tool catalogue (name, description, `read_only`, `destructive`, input schema) as JSON |
| `md_agent_open` | `MdAgent *(const char *vault_path, const char *api_key)` | agent_ffi.rs | Opens a chat session; the API key stays in Rust only, never crosses into the web view; `NULL` if vault unusable |
| `md_agent_close` | `void(MdAgent *agent)` | agent_ffi.rs | Closes a session (a turn in flight finishes on its own thread, events simply undrained); NULL-safe |
| `md_agent_send_start` | `bool(MdAgent *agent, const char *text)` | agent_ffi.rs | Starts a turn on a background thread; returns `false` (starts nothing) if a turn is already in progress |
| `md_agent_poll_event` | `char *(MdAgent *agent)` | agent_ffi.rs | Blocks for the next event as JSON (`text`/`thinking`/`tool_started`/`tool_finished`/`refused`/`failed`/`done`); `NULL` marks turn end |

Opaque handle types: `MdAsset` (`#[repr(C)]` struct, borrowed static-lifetime data — never
freed), `MdVault`, `MdAgent` (both `Box::into_raw`/`Box::from_raw` opaque pointers).

**No-callback design**: Rust never calls back into Swift/C#. `md_agent_send_start` spawns
a background `std::thread`; events flow through an `mpsc::channel`; the host polls
`md_agent_poll_event` from its own background thread in a loop until `NULL`. This avoids
the GC/lifetime hazards of Rust calling into managed code (especially C#, which would need
`GCHandle` pinning) — exactly the "no callback ABI" shape the design plan called for.

`vault_ffi.rs`'s own doc comment states the intent plainly: it's "deliberately three
functions wide" (`open`/`close`/`call` plus the tools-catalogue getter) so that **adding a
new vault tool never requires touching the header, the Swift facade, or the C# facade** —
only `markdown_vault::tools`.

## 3. `markdown_vault` — the security boundary and storage layer

### 3.1 `confine.rs` — path confinement algorithm

`resolve_in(root: &Path, input: &str, must_exist: bool) -> Result<PathBuf, ConfineError>`
is the sole function; every mutating/reading operation in the crate is required to route
through it. Algorithm:

1. Reject interior NUL bytes outright (`InteriorNul`).
2. Trim whitespace, strip a leading `/` (a convenience, not an absolute-path escape hatch
   — inputs are contractually vault-relative).
3. Reject empty/slash-only input (`Empty`).
4. Walk `Path::components()`: any `ParentDir` (`..`) is refused outright — **not
   normalized away** ("`a/../b` is a mistake worth surfacing"); any `Prefix`/`RootDir`
   component (Windows drive letters, UNC paths, or a `/` that survived the strip) is
   refused as `Traversal`.
5. Canonicalize `root` itself (`RootUnavailable` if the vault root is gone).
6. If `root.join(raw)` exists: canonicalize it (resolves symlinks) and proceed to the
   containment check.
7. If it doesn't exist and `must_exist == true`: `NotFound`.
8. If it doesn't exist and `must_exist == false` (a write target): canonicalize the
   **parent** instead, then re-attach the file name — closing the same symlink hole for
   writes into a symlinked directory whose target file doesn't exist yet.
9. Final containment check: `resolved.starts_with(&root)` — component-wise, not a string
   prefix, which specifically guards against a sibling directory like `/vault-evil`
   textually starting with `/vault` (there's a dedicated test for exactly this).

Test coverage is exhaustive (16 tests): plain/nested/leading-slash/`./` paths,
empty/slash-only/`..`-in-various-positions/interior-NUL rejections,
absolute-path-fails-to-`NotFound` (not silently reinterpreted), percent-encoding is *not*
decoded (`%2e%2e` stays a literal filename, never becomes `..`), symlink escapes (both for
existing-file reads and non-existent-file writes through a symlinked directory), the
sibling-prefix-string bug, and the create-vs-read distinction via `must_exist`.

`Vault::resolve_for_create` (in `store.rs`) extends this for `mkdir -p`-style creates whose
parent chain doesn't exist yet: walks up to the deepest existing ancestor, confines *that*,
then re-attaches the missing tail — still checked against `starts_with(&self.root)`.

### 3.2 `store.rs` — CRUD

`Vault::open(root)` canonicalizes root, opens/inits git history, and **bakes a baseline
commit** if the adopted folder has no history yet. This is load-bearing: without a
baseline, undoing the very first agent-made change would have nothing to revert to and
would delete the file instead of restoring pre-existing content (tested:
`the_first_change_is_undoable_back_to_the_original`).

All methods route through `resolve_in`, and mutations through `history.commit_all`:

- `read(path)` — rejects directories (`WrongKind`) and non-UTF-8 files (`NotText`).
- `list(dir)` — immediate children only, folders-first then alpha, hides dotfiles
  (including `.git`) and non-Markdown files.
- `write(path, contents)` — create-or-replace, commits `"Write {path}"`.
- `create_file(path, contents)` — like `write` but refuses if something already exists
  (`Exists`).
- `edit(path, old_text, new_text)` — the targeted-replace tool: requires `old_text` to
  appear **exactly once** (0 occurrences → `NoMatch`, >1 → `AmbiguousMatch(n)`); refuses
  rather than guessing, and refuses an empty `old_text`. This is deliberately the tool the
  agent's system prompt tells the model to prefer over `write_note`.
- `create_folder(path)` — `mkdir -p` semantics via `resolve_for_create`.
- `move_path(from, to)` — refuses if destination exists; creates missing destination
  parents.
- `delete(path)` — refuses to delete the vault root itself; otherwise removes a file or
  recursively removes a directory — fully recoverable via git revert, so there's no
  separate `.trash/`.
- `undo(commit_id)` — thin wrapper over `History::revert`.

17 tests, including a dedicated "confinement reaches every entry point" test that drives
every mutating method with a `../escaped.md` path and asserts none of them touch the
filesystem outside the vault.

### 3.3 `history.rs` — git-backed undo

Backed by `git2` (libgit2 bindings), strictly local — **never adds a remote or pushes**.
`History::open_or_init(root)` opens an existing repo or inits one with `no_reinit(true)`;
a vault that's already git-tracked keeps its existing history rather than gaining a
parallel one.

- `is_dirty()` — `git2::StatusOptions` with untracked included, ignored excluded; used by
  `markdown_agent::Agent::send` to refuse starting a turn on a dirty tree.
- `commit_all(message)` — stages everything, writes the tree, compares against `HEAD`'s
  tree id, and **returns `Ok(None)` (not an error) if nothing changed** — an unchanged
  write is honestly "no commit," not a spurious one. Signature preference: the user's own
  configured git identity via `repo.signature()`, falling back to
  `Signature::now("Markdown", "markdown@localhost")`.
- `revert(commit_id)` — applies the commit's **inverse as a new commit** (`repo.revert`),
  never rewriting history ("an undo is itself undoable"). On conflict it forcibly cleans
  up (`cleanup_state` + forced `checkout_head`) and returns `HistoryError::Conflict` with
  the truncated (8-char) commit id.
- `log(limit)` — newest-first commit list via `revwalk` sorted by `git2::Sort::TIME`;
  returns empty (not an error) before the first commit.

9 tests cover: repo init, adopting existing history without discarding it, commit-a-file,
no-op writes are not commits, dirty-tree detection, byte-exact restore after revert (both
overwrite and delete cases), and that revert adds a commit rather than rewriting history.

### 3.4 `outline.rs` — heading extraction

`outline(markdown) -> Vec<Heading>` is a hand-rolled ATX-heading (`#`…`######`) line
scanner that tracks fenced-code-block state (matching the opening fence's exact character)
so a heading-looking line inside a code fence isn't mistaken for structure. Handles
`{#custom-id}` heading-attribute syntax to let authors pin an anchor explicitly; strips
trailing decorative `##` closers; de-duplicates ids (`-2`, `-3`, …); falls back to
`section-N` for a heading with no alphanumeric content at all.

`slugify(text)` is **deliberately mirrored byte-for-byte** against
`vue-project/src/composables/useDocumentOutline.ts`'s slug rule (lowercase, NFKD-normalize,
keep only alphanumerics, collapse everything else to a single `-`, trim leading/trailing
`-`). Its test values were captured by running the TypeScript rule directly rather than
derived independently — **any future change to either side must keep both in lockstep**,
or search-result anchors and preview anchors will silently diverge. CJK text is preserved
intact; a mid-word combining mark (e.g. "Über" → "u-ber") leaves a visible separator,
matching browser behavior exactly, oddity included.

### 3.5 `search.rs` — lexical search

Pure substring, case-insensitive, no index maintained — this **is** the entire retrieval
layer (no embeddings, nothing to keep fresh). Caps (mirroring the macOS
`FolderSearch.swift` this replaces): `MAX_FILE_BYTES = 4 MiB` (larger files are
name-matched only), `MAX_SNIPPETS_PER_FILE = 3`, `MAX_HITS = 200`,
`SNIPPET_CHARS = 160` (truncated with `…`).

Walks the vault tree skipping dotfile-prefixed entries (so `.git` is invisible), filters
to markdown files. Each hit reports `path`, `name`, `name_matched` (sorts name matches
above content-only matches), and up to 3 `Snippet`s (`line`, `text`, and the enclosing
heading + slug via `outline()`) — letting a caller cite `note.md#some-heading` and have it
resolve to the right section. 12 tests cover ranking, exclusion rules, heading
attribution, line numbers, case-insensitivity, blank-query handling, snippet capping, long
lines, huge-file name-only fallback, and nested-folder discovery.

### 3.6 `tools.rs` — the shared tool dispatch surface

`call(vault: &Vault, name: &str, input: &Value) -> Result<Value, String>` plus a static
catalogue `TOOLS: &[ToolSpec]` and `schema(name) -> Option<Value>`. **This is the single
implementation shared verbatim by the C ABI** (`md_vault_call`/`md_vault_tools`), and thus
by everything that consumes those — the in-app agent (`markdown_agent::request::tool_definitions()`
pulls straight from `markdown_vault::TOOLS`/`schema`). Every schema has
`additionalProperties: false` and an explicit `required` array (asserted by test).

| Tool | read_only | destructive | Input | Output |
|---|---|---|---|---|
| `list_notes` | ✅ | — | `{dir?: string}` | `{entries: ListEntry[]}` |
| `read_note` | ✅ | — | `{path: string}` | `{content: string}` |
| `search_notes` | ✅ | — | `{query: string, limit?: int}` | `{hits: SearchHit[]}` |
| `outline` | ✅ | — | `{path: string}` | `{headings: Heading[]}` |
| `create_note` | ❌ | — | `{path, content}` | `{commit, changed}` |
| `edit_note` | ❌ | — | `{path, old_text, new_text}` | `{commit, changed}` |
| `write_note` | ❌ | — | `{path, content}` | `{commit, changed}` |
| `create_folder` | ❌ | — | `{path}` | `{commit, changed}` |
| `move` | ❌ | ✅ | `{from, to}` | `{commit, changed}` |
| `delete` | ❌ | ✅ | `{path}` | `{commit, changed}` |
| `undo` | ❌ | — | `{commit}` | `{commit}` |
| `import_asset` | ❌ | — | `{filename, content_base64}` | `{path, mime, commit, changed}` |
| `read_asset` | ✅ | — | `{path}` | `{content_base64, mime}` |

`import_asset` (`store.rs`) copies bytes into `assets/` under a name derived from
`filename`: reduced to its basename (no directory components honoured — a drop/paste
target, not a path), whitespace characters replaced with `_` via `sanitize_filename`
(inserted into a Markdown link verbatim, so a raw space would need URL-escaping the
editor doesn't do), then de-collided with a numeric suffix (`photo.png` → `photo-1.png`)
rather than clobbering or failing. Capped at `MAX_ASSET_BYTES` (25 MiB). `read_asset` is
the binary counterpart to `read_note` (`fs::read`, not `read_to_string`, so it also
serves images/PDFs/other binary attachments) — used both by the WebView's asset-serving
fallback (an `<img>` tag inside a rendered note) and, on macOS, directly by
`VaultStore.readAsset` for drag-drop import round-trips. Neither is scoped to `assets/`
on the read side — `read_asset` can read any vault-relative path, same confinement as
every other tool.

(`committed()` returns `{"changed": false}` for a no-op write, or `{"commit": "<git
oid>", "changed": true}` for an actual change, so callers/models can tell "nothing needed
doing" from "something changed, here's the undo handle.") Only `move` and `delete` are
`destructive` (asserted by test); no tool is both `read_only` and `destructive` (also
asserted — this invariant is what external `--allow-write`/`--allow-destructive` gating
trusts). Errors return as human-readable `Result::Err(String)` meant for the model to read
and act on, never a panic. A dedicated test drives every mutating/reading tool with a
`../escaped.md` path to confirm confinement holds through the whole dispatch layer.

## 4. `markdown_agent` — the Claude agent loop

### 4.1 `request.rs` — request construction

`AgentConfig::new(api_key)` defaults: `model = "claude-opus-5"`, `effort = "high"`,
`max_write_calls = 5` (hard ceiling `WRITE_CALL_CEILING = 50`, enforced via
`write_call_budget() = max_write_calls.min(ceiling)`), `max_tool_rounds = 8`,
`base_url = "https://api.anthropic.com"` (overridable — used by every test via a local
stub server).

`body(config, system, messages)` builds the exact `POST /v1/messages` JSON:

- `max_tokens: 64_000`, `stream: true` (a non-streamed response this large risks an HTTP
  timeout).
- `thinking: {type: "adaptive", display: "summarized"}` — **not `budget_tokens`**, which
  the code and a test both assert is rejected (400) on Opus 5.
- `output_config: {effort: config.effort}`.
- `fallbacks: "default"` plus header `anthropic-beta: server-side-fallback-2026-07-01` —
  routes around a policy decline via server-side model fallback without the client
  maintaining its own model list.
- `system` is a one-element array carrying `cache_control: {type: "ephemeral"}` — the
  **only** cache breakpoint (a test asserts neither `tools[0]` nor `messages[0]` carries
  `cache_control`). Render order is tools → system → messages, so the breakpoint caches
  the tool list and system prompt together; only the conversation varies turn to turn.
- `tools: tool_definitions()`, pulled directly from `markdown_vault::TOOLS`/`schema` — the
  agent's tool list can never drift from the vault's own catalogue.
- No assistant prefill: a test checks the last message in a freshly built body is always
  `role: "user"`, since a trailing assistant turn is also a 400 on Opus 5.

`system_prompt(vault_name)` instructs the model: paths are vault-relative, prefer
`edit_note` over `write_note`, prefer `search_notes`/`outline` over reading everything,
changes are auto-applied and always undoable, "make the change asked for and no more," and
ask rather than guess on ambiguity.

`Message::tool_results` batches **every** tool result from one assistant turn into a
**single** user message (multiple content blocks) — deliberately, per its comment,
because splitting them across messages "teaches the model to stop asking for tools in
parallel." `tool_result_block(id, content, is_error)` only sets `is_error: true` when
applicable.

### 4.2 `session.rs` — the loop itself

`Agent::send(user_text, emit: &mut dyn FnMut(AgentEvent))` runs synchronously on whatever
thread calls it (the FFI layer puts that on a spawned background thread):

1. **Refuses on a dirty vault tree** before making any request at all
   (`history().is_dirty()`) — a test confirms the stub server receives zero requests in
   this case.
2. Starts a per-turn JSONL `Trace`, pushes the user message.
3. Loops up to `config.max_tool_rounds` times, calling `round()` (one streamed HTTP
   round-trip):
   - If refused (`stop_reason == "refusal"`), emits `AgentEvent::Refused{category,
     explanation}` and stops (not treated as an error).
   - Otherwise pushes the assembled assistant content verbatim (thinking blocks included,
     unchanged — required for replay integrity; a `signature_delta` field surviving
     round-trip is directly tested).
   - If the model didn't ask for tools, emits `Done{stop_reason}` and returns.
   - Otherwise runs `run_tools()` and pushes **all** results as one batched user message
     before looping again.
4. If `max_tool_rounds` is exhausted without finishing, emits a `Failed` message naming the
   round count — the loop-cap safety net (tested with a 10-turn tool-loop script capped at
   `max_tool_rounds = 3`, confirming exactly 3 requests are made).

`run_tools()` is where the **write cap is enforced pre-dispatch**: for each `tool_use`
block, it checks whether the tool is mutating
(`markdown_vault::tools::spec(name).is_some_and(|s| !s.read_only)`) and whether
`writes_used >= budget`. If so, the tool is **never called** — it's answered with a
hard-coded `is_error: true` result explaining the limit, and the write counter isn't
incremented. This check-then-maybe-call ordering is what makes the cap "refused before
dispatch," not merely "capped after the fact" (tested:
`the_write_cap_refuses_before_the_file_changes` — with `max_write_calls=1` and two write
calls in one model turn, only the first file is created on disk). Reads never consume the
write budget. A failing tool call always comes back as `is_error: true` — never silently
dropped.

`Trace` writes best-effort JSONL (`prompt`/`model_call`/`tool_call`/`tool_result`/
`error`/`refusal`/`stream_error`/`done`, each with a sequence number and millisecond
timestamp) to a caller-supplied directory **outside the vault** — a test explicitly
confirms no trace file ever appears inside the vault root, since it would otherwise get
swept into the next `commit_all("*")` and pollute the user's own note history. Trace I/O
failures are swallowed silently — a turn must never fail because a log couldn't be
written, but this also means a broken trace directory fails completely silently, with no
diagnostic, in exactly the situation where "why did it do that" investigations matter most.

### 4.3 `sse.rs` — SSE parsing/reassembly

`Assembler::feed(line)` parses only `data:` lines (ignores `event:` lines entirely — every
`data:` payload names its own type), dispatching on the JSON payload's `type` field:
`content_block_start`/`delta`/`stop`, `message_delta` (captures `stop_reason`,
`stop_details`, `usage`), `message_start` (initial `usage`), `error`, and silently ignores
everything else (`ping`, `message_stop`, future types).

Two concurrent obligations: emit `StreamEvent`s (`Text`, `Thinking`, `ToolStarted`,
`Error`) live for UI updates, while also accumulating each content block's exact final
JSON shape in `Assembled.content` for verbatim replay on the next request. Tool-call
arguments accumulate as raw `partial_json` text fragments across multiple
`input_json_delta` events and are only parsed as JSON once, at block-close (`seal()`) —
**must be parsed, never string-matched**, since escaping in these fragments varies by
model. Malformed accumulated JSON degrades to an empty `{}` input rather than panicking,
letting the tool layer reject it with a model-readable message. A truncated stream (cut
mid-block, no `content_block_stop`/`message_delta` ever arriving) still produces valid
replayable content via `finish()`'s forced `seal()` over every still-open block — tested
directly.

`thinking_delta` text is appended and, if non-empty, emitted as `StreamEvent::Thinking`
(an empty delta, under `display: "omitted"`, emits nothing); `signature_delta` accumulates
into the block's `signature` field but is never surfaced as an event — pure
replay-integrity data.

### 4.4 Event delivery to hosts

Covered under §2.3 — the `md_agent_send_start`/`md_agent_poll_event` pair, backed by an
`mpsc::channel` and a spawned `std::thread`. The mutex guarding `current_turn` is
**released before** the blocking `rx.recv()` call (taken out, then put back after each
successful receive), specifically so a concurrent `md_agent_send_start` call can correctly
observe "still busy" without deadlocking behind a long-running network call (tested:
`a_second_send_while_one_is_in_flight_is_refused`).

## 5. Test coverage summary

Every module except plain re-export `lib.rs` files has an inline `#[cfg(test)] mod
tests`. Approximate counts:

| Crate | File | Tests |
|---|---|---|
| markdown_core | render.rs | 10 |
| markdown_core | assets.rs | 5 |
| markdown_core | ffi.rs | 6 |
| markdown_core | agent_ffi.rs | 5 |
| markdown_core | vault_ffi.rs | 9 |
| markdown_vault | confine.rs | 16 |
| markdown_vault | store.rs | 18 |
| markdown_vault | history.rs | 9 |
| markdown_vault | outline.rs | 11 |
| markdown_vault | search.rs | 12 |
| markdown_vault | tools.rs | 13 |
| markdown_agent | request.rs | 8 |
| markdown_agent | session.rs | 11 |
| markdown_agent | sse.rs | 10 |

**~143 unit tests total**, all pure-Rust and network-free — the agent's HTTP layer is
tested against an in-process raw `TcpListener` stub server replaying canned SSE
transcripts (no tokens, no real API calls, deterministic failure injection e.g. pointing
at `127.0.0.1:1` to force connection-refused). No integration-test crate or workspace-level
`tests/` directory exists — testing is inline per module, which fits the crates' pure
function/struct design.

Against the design plan's "Verification" checklist: confinement (done, exhaustively),
sanitization (done), agent loop without network via a stub server (done), caps/undo tested
pre-dispatch (done). The MCP-server-via-inspector check, end-to-end app instrumentation,
whole-toolchain clean builds, and a live-write smoke test are all manual/integration steps
that can't be confirmed from source alone.

## 6. Build and tooling

See `build-and-development.md` for the full walkthrough. Notable Rust-specific points:

- `build-xcode.sh` builds `markdown_core` per-architecture and `lipo`-merges the result;
  on macOS it also builds and code-signs the vendored `solomd-mcp` binary into the app
  bundle — a previously-debugged, easy-to-regress gotcha (see that doc for why).
- `MARKDOWN_SKIP_UI_BUILD=1 cargo build` bypasses the Vue build step, reusing the existing
  `vue-project/dist`.
- No `.cargo/config.toml` exists anywhere in the workspace — Windows cross-compilation
  configuration, if any, lives entirely in the C# project's MSBuild targets, not in the
  Rust workspace itself.

## 7. Gaps, deviations, and gotchas

1. **`markdown_mcp` (the plan's proposed fresh crate) was never built** — `solomd-mcp` was
   vendored instead, with its own independent vault/security logic. The real next step for
   anyone picking up "Phase 1" work is the convergence `PROVENANCE.md` describes (repoint
   `solomd-mcp`'s tool bodies at `markdown_vault::tools::call`, delete its
   `safety.rs`/`workspace.rs`), not building yet another server.
2. **`git2` version coupling across the workspace** is a real constraint (`libgit2-sys`'s
   `links = "git2"` forces one resolved build across all workspace members) — worth
   re-verifying it still links cleanly given `markdown_vault` and `solomd-mcp` differ on
   the `vendored-libgit2` feature flag.
3. **`md_vault_tools()`'s `read_only`/`destructive` flags are load-bearing for external
   trust decisions** (e.g. an MCP server's `--allow-write`/`--allow-destructive` gates) —
   any new tool added to `TOOLS` must get these flags right the first time, since hosts
   trust them without further validation.
4. **`markdown_agent` requires a clean vault working tree before every turn**, with no
   partial/scoped alternative — a real UX constraint that autosave/dirty-buffer logic at
   the app layer has to respect.
5. **No runtime model-selection surface** — `md_agent_open` only takes a vault path and API
   key; changing models requires a Rust code change or a new FFI parameter.
6. **The MCP server is macOS-only** in the current build pipeline; Windows has no bundled
   external-agent access surface at all yet.
