//
//  VaultStore.swift
//  Markdown
//
//  Swift facade over the Rust `markdown_vault` library, which owns every read and write of
//  the notes folder along with its history. Mirrors VaultStore.cs on Windows.
//
//  Deliberately thin: one JSON call reaches every tool, so adding a tool is a change in
//  Rust alone. Path safety lives there too — nothing here validates a path, because
//  `confine.rs` already refuses anything outside the vault.
//

import Foundation

nonisolated enum VaultError: LocalizedError {
    /// The vault could not be opened at all.
    case unavailable(URL)
    /// The Rust side rejected the operation; the message is written for a person to read.
    case rejected(String)
    /// The reply was not the shape the ABI promises.
    case malformedReply

    var errorDescription: String? {
        switch self {
        case .unavailable(let url): "Could not open the vault at \(url.path)."
        case .rejected(let message): message
        case .malformedReply: "The vault returned an unexpected reply."
        }
    }
}

/// An open notes vault.
///
/// `nonisolated` because it is a handle wrapper with no shared mutable state of its own, and
/// because `deinit` has to be able to release the handle.
nonisolated final class VaultStore {
    private let handle: OpaquePointer

    /// Opens `root`, initialising history and recording a baseline commit on first use.
    init(root: URL) throws {
        guard let handle = root.path.withCString({ md_vault_open($0) }) else {
            throw VaultError.unavailable(root)
        }
        self.handle = handle
    }

    deinit {
        md_vault_close(handle)
    }

    // MARK: - The one call

    /// Runs a vault tool and returns its `result` object.
    @discardableResult
    func call(_ name: String, _ input: [String: Any] = [:]) throws -> [String: Any] {
        let arguments = try JSONSerialization.data(withJSONObject: input)
        guard let json = String(data: arguments, encoding: .utf8) else {
            throw VaultError.malformedReply
        }

        guard let raw = name.withCString({ name in
            json.withCString { md_vault_call(handle, name, $0) }
        }) else {
            throw VaultError.malformedReply
        }
        defer { md_string_free(raw) }

        let reply = String(cString: raw)
        guard let data = reply.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw VaultError.malformedReply
        }

        // A failing tool is an ordinary reply carrying a message worth showing.
        guard object["ok"] as? Bool == true else {
            throw VaultError.rejected(object["error"] as? String ?? "The vault refused that.")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Typed conveniences

    func read(_ path: String) throws -> String {
        guard let content = try call("read_note", ["path": path])["content"] as? String else {
            throw VaultError.malformedReply
        }
        return content
    }

    /// Returns the commit id, or `nil` when the contents were already what was asked for.
    @discardableResult
    func write(_ path: String, contents: String) throws -> String? {
        try call("write_note", ["path": path, "content": contents])["commit"] as? String
    }

    @discardableResult
    func createFile(_ path: String, contents: String = "") throws -> String? {
        try call("create_note", ["path": path, "content": contents])["commit"] as? String
    }

    @discardableResult
    func createFolder(_ path: String) throws -> String? {
        try call("create_folder", ["path": path])["commit"] as? String
    }

    @discardableResult
    func move(from: String, to: String) throws -> String? {
        try call("move", ["from": from, "to": to])["commit"] as? String
    }

    @discardableResult
    func delete(_ path: String) throws -> String? {
        try call("delete", ["path": path])["commit"] as? String
    }

    @discardableResult
    func undo(commit: String) throws -> String? {
        try call("undo", ["commit": commit])["commit"] as? String
    }

    /// Relative path of `url` inside this vault, which is the only form the vault accepts.
    static func relativePath(of url: URL, in root: URL) -> String? {
        let target = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard target.hasPrefix(base + "/") else { return nil }
        return String(target.dropFirst(base.count + 1))
    }
}
