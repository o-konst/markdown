//! The Vue `dist/` bundle, embedded into the library as static byte slices.

include!(concat!(env!("OUT_DIR"), "/web_assets.rs"));

/// Entry point served for `/` and for any unknown path (single page app fallback).
pub const INDEX_PATH: &str = "index.html";

/// A single file of the compiled web UI.
pub struct WebAsset {
    /// Path relative to the Vite `dist/` root, e.g. `assets/index-abc123.js`.
    pub path: &'static str,
    /// NUL terminated MIME type, so it can be handed to C without allocating.
    pub mime: &'static str,
    pub bytes: &'static [u8],
}

impl WebAsset {
    pub fn mime(&self) -> &'static str {
        self.mime.trim_end_matches('\0')
    }

    pub(crate) fn mime_ptr(&self) -> *const core::ffi::c_char {
        self.mime.as_ptr().cast()
    }
}

/// Looks up an embedded asset, normalising the URL path first.
///
/// Directory-style requests (`/`, `/preview`) resolve to `index.html` so client side
/// routing keeps working inside the web view.
pub fn lookup(request_path: &str) -> Option<&'static WebAsset> {
    let path = normalize(request_path);
    exact(&path)
        .or_else(|| exact(&format!("{path}/index.html")))
        .or_else(|| exact(INDEX_PATH))
}

/// Like [`lookup`], but without the single page app fallback.
pub fn exact(path: &str) -> Option<&'static WebAsset> {
    let path = normalize(path);
    WEB_ASSETS.iter().find(|asset| asset.path == path)
}

/// Every embedded asset, sorted by path.
pub fn all() -> &'static [WebAsset] {
    WEB_ASSETS
}

fn normalize(request_path: &str) -> String {
    let path = request_path
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .trim_matches('/');

    if path.is_empty() {
        return INDEX_PATH.to_string();
    }

    // Reject traversal segments; embedded assets are a flat, known set anyway.
    path.split('/')
        .filter(|segment| !segment.is_empty() && *segment != "." && *segment != "..")
        .collect::<Vec<_>>()
        .join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serves_index_for_root() {
        assert_eq!(lookup("/").unwrap().path, INDEX_PATH);
        assert_eq!(lookup("").unwrap().path, INDEX_PATH);
    }

    #[test]
    fn falls_back_to_index_for_unknown_routes() {
        assert_eq!(lookup("/some/spa/route").unwrap().path, INDEX_PATH);
        assert!(exact("/some/spa/route").is_none());
    }

    #[test]
    fn strips_query_and_traversal() {
        assert_eq!(lookup("/index.html?v=1").unwrap().path, INDEX_PATH);
        assert_eq!(lookup("/../../index.html").unwrap().path, INDEX_PATH);
    }

    #[test]
    fn bundles_hashed_javascript() {
        assert!(all().iter().any(|a| a.path.ends_with(".js")));
        assert!(all().iter().all(|a| !a.bytes.is_empty()));
    }

    #[test]
    fn index_is_html() {
        assert_eq!(exact(INDEX_PATH).unwrap().mime(), "text/html; charset=utf-8");
    }
}
