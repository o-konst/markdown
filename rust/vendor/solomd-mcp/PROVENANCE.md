# solomd-mcp — vendored fork

This crate is **not original work in this repository.** It is a vendored copy of the
`mcp-server` crate from **SoloMD**, used under the MIT licence.

- Upstream: <https://github.com/zhitongblog/solomd> (`mcp-server/`)
- Upstream version: `solomd-mcp` 0.4.1
- Copyright (c) 2026 xiangdong li — see [`LICENSE`](LICENSE)
- Copied: 2026-08-24

The MIT licence text is reproduced verbatim in `LICENSE` and must stay with this code. Keep
the copyright line intact in any further redistribution.

## Changes made when vendoring

Kept as close to upstream as possible, so future upstream fixes stay easy to merge.

1. **`git2` bumped 0.19 → 0.21.** `libgit2-sys` declares `links = "git2"`, so a Cargo
   workspace may contain only one version of it, and `markdown_vault` already uses 0.21.
   The only source change this forced: `Commit::summary()` returns
   `Result<Option<&str>>` in 0.21 where it returned `Option<&str>` in 0.19.
2. **Four tools removed**, because they call SoloMD services this app does not have:
   - `share_url` — returns `https://solomd.app/share/…` links. Shipping it would have this
     app emit links to a different product's website.
   - `sync_status` — reads `.solomd/sync.json`, SoloMD's GitHub-sync config.
   - `export_note` — shells out to `solomd-export.mjs` from the SoloMD app bundle.
   - `read_agent_trace` — reads `.solomd/agent-runs/*/trace.jsonl`.

   Their argument structs, helper functions, the `trace_reader` module, and the tests
   covering them were removed with them.
3. **`--help` text** updated to stop advertising the removed tools.
4. **Local profile settings** dropped from `Cargo.toml`; profiles come from the workspace root.

Nothing else was touched. The 11 remaining tools, the `--allow-write` gate, workspace
federation, path confinement in `safety.rs`, and both transports are upstream's.

## The duplication to be aware of

This crate carries its **own** implementations of path confinement (`safety.rs`), vault
walking and search (`workspace.rs`), and git history — all of which now also exist in
`markdown_vault`, written for this app. That means two copies of the security boundary in
one repository, which is exactly what putting the vault logic in Rust was meant to avoid.

It is a deliberate trade for getting a proven, shipping MCP server working immediately. The
convergence step, when it is worth doing, is to keep this crate's `main.rs` (CLI, transports,
the `--allow-write` gate, federation) and re-point its tool bodies at
`markdown_vault::tools::call`, deleting `safety.rs` and `workspace.rs`.
