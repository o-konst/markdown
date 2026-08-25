//! The notes vault: everything that reads or changes files on disk.
//!
//! This crate is the single implementation shared by all three front ends — the macOS and
//! Windows apps (through the `markdown_core` FFI), the MCP server, and the in-app agent.
//! Nothing above it is allowed to touch the filesystem directly, because [`confine`] is the
//! security boundary and it only works if every path goes through it.

pub mod confine;
pub mod history;
pub mod outline;
pub mod search;
pub mod store;
pub mod tools;

pub use confine::{resolve_in, ConfineError};
pub use history::{History, HistoryError};
pub use outline::{outline, slugify, Heading};
pub use search::{search, SearchHit, Snippet};
pub use store::{ListEntry, Vault, VaultError};
pub use tools::{call, schema, ToolSpec, TOOLS};
