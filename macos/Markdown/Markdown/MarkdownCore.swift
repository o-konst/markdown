//
//  MarkdownCore.swift
//  Markdown
//
//  Swift facade over the Rust `markdown_core` static library, which renders Markdown
//  and carries the compiled Vue web UI inside itself.
//

import Foundation

nonisolated enum MarkdownCore {
    /// A file of the web UI that was compiled into the Rust library.
    struct Asset {
        let data: Data
        let mimeType: String
    }

    /// Version of the Rust core library.
    static var version: String {
        String(cString: md_version())
    }

    /// Number of web UI files embedded in the Rust library.
    static var assetCount: Int {
        md_asset_count()
    }

    /// Renders Markdown to an HTML fragment.
    static func render(_ markdown: String) -> String {
        guard let rendered = md_render(markdown) else { return "" }
        defer { md_string_free(rendered) }
        return String(cString: rendered)
    }

    /// Looks up an embedded web UI file by URL path, e.g. `/assets/index.js`.
    /// Unknown paths resolve to `index.html`.
    static func asset(forPath path: String) -> Asset? {
        var asset = MdAsset()
        guard md_asset_lookup(path, &asset),
              let bytes = asset.data,
              let mime = asset.mime
        else {
            return nil
        }
        return Asset(
            data: Data(bytes: bytes, count: asset.len),
            mimeType: String(cString: mime)
        )
    }

    /// Whether `path` matches a real embedded web UI file exactly — unlike `asset(forPath:)`,
    /// without its single-page-app fallback to `index.html`. Use this, not `asset(forPath:)`,
    /// to tell "this is a genuine embedded UI route" apart from "nothing here" — `asset(forPath:)`
    /// would otherwise always report success (as `index.html`) for literally any path.
    static func embeddedAssetExists(forPath path: String) -> Bool {
        md_asset_exists(path)
    }
}
