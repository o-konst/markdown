//! Rust backend for the macOS Markdown app.
//!
//! Two responsibilities:
//! * hosting the Vue single page app, which is compiled into this library at build time
//!   (see `build.rs`) and served to a `WKWebView` through a custom URL scheme handler;
//! * rendering Markdown to HTML, so the host app never has to do it in Swift or JavaScript.

pub mod assets;
pub mod agent_ffi;
pub mod ffi;
pub mod render;
pub mod vault_ffi;

pub use assets::{WebAsset, INDEX_PATH};
pub use render::render_markdown;

/// Semantic version of the core library, reported to the web UI for diagnostics.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
