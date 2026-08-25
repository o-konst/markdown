# Documentation index

Deep-reference documentation for the Markdown app, a cross-platform (macOS + Windows)
notes app with a shared Rust core and an embedded Vue web UI. This index links each
subsystem doc; start with `architecture.md` for the big picture.

- **[architecture.md](architecture.md)** — system overview, component diagram, data
  flow, and a per-platform feature-parity matrix.
- **[rust-core.md](rust-core.md)** — the three Rust crates (`markdown_core`,
  `markdown_vault`, `markdown_agent`) and the vendored `solomd-mcp` server: full C ABI
  table, vault tool catalogue, agent loop internals.
- **[macos-app.md](macos-app.md)** — the SwiftUI app: workspace/document model, FFI
  facades, WebView bridge, AI chat feature, auth/credentials.
- **[windows-app.md](windows-app.md)** — the WinUI 3 (C#) app: current (minimal) scope
  and an explicit gap list against macOS.
- **[frontend.md](frontend.md)** — the embedded Vue 3 app: native bridge protocol,
  composables, components, build quirks.
- **[security.md](security.md)** — path confinement, HTML sanitization, credential
  handling, write/loop caps, and known open gaps.
- **[build-and-development.md](build-and-development.md)** — how to build, run, and
  test every piece, plus the non-obvious build-script workarounds.

For AI-assistant-driven work in this repo, also see `.claude/plans/ai-assistant-mcp-and-chat.md`
(the original design plan) and the root `CLAUDE.md`. Most of that plan is now implemented;
the docs here describe **current, verified code state**, and call out where they diverge
from the plan.

## How this documentation was produced

Generated 2026-08-24 by reading every source file across all four platforms (Swift, C#,
Rust, TypeScript/Vue) and cross-checking against the design plan. Treat it as a snapshot:
re-verify specifics (function signatures, file paths, test counts) against the code before
relying on them for anything load-bearing, especially as the project evolves.
