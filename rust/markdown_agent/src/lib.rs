//! The Claude agent loop over a notes vault.
//!
//! Shared by both app shells: the loop, the HTTP call, the caps, and the trace all live here,
//! so each platform only has to render a chat panel and keep the API key somewhere safe.
//!
//! The key never reaches the web view. A note can contain raw HTML, so anything the web view
//! can read is exfiltratable by a crafted note; the key is passed in from the host's keychain
//! at call time and stays on this side of the bridge.

pub mod request;
pub mod session;
pub mod sse;

pub use request::{AgentConfig, Message};
pub use session::{Agent, AgentEvent};
pub use sse::{Assembled, Assembler, StreamEvent};
