//
//  RecentVaults.swift
//  Markdown
//
//  Persists which folders/files the app has previously been granted access to, so they
//  can be reopened later — including after a relaunch — without going through
//  `.fileImporter` again. See `.claude/plans/recent-vaults-plan.md`.
//

import Foundation
import Observation

struct RecentVaultEntry: Codable, Identifiable, Equatable {
    var bookmark: Data
    var displayName: String
    var path: String
    var isFolder: Bool
    var lastOpenedAt: Date

    var id: String { bookmark.base64EncodedString() }
}

@Observable
final class RecentVaultsStore {
    private static let storageKey = "recentVaults"
    private static let maxEntries = 10

    /// Shared with any other target that adopts this App Group (a future Share Extension,
    /// widget, or the MCP server sidecar) — declared in `Markdown.entitlements`. Falls back
    /// to `.standard` if the group container isn't actually available (e.g. the entitlement
    /// hasn't been provisioned yet for this build), so recent-vault tracking still works
    /// stand-alone rather than silently doing nothing.
    private static let appGroupID = "group.com.ogay.webviewtest.Markdown"

    private(set) var entries: [RecentVaultEntry]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: RecentVaultsStore.appGroupID) ?? .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([RecentVaultEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Records (or moves to the front of) the recent list. Called after every successful
    /// open, whether from a fresh picker pick or from `Workspace.openRecent(_:)` — so
    /// reopening a recent item also refreshes its position at the front.
    func record(url: URL, isFolder: Bool) {
        guard let bookmark = Self.makeBookmark(for: url) else { return }

        var updated = entries.filter { $0.path != url.path }
        updated.insert(
            RecentVaultEntry(
                bookmark: bookmark,
                displayName: url.lastPathComponent,
                path: url.path,
                isFolder: isFolder,
                lastOpenedAt: Date()
            ),
            at: 0
        )
        if updated.count > Self.maxEntries {
            updated.removeLast(updated.count - Self.maxEntries)
        }
        entries = updated
        persist()
    }

    /// Resolves a stored bookmark back to a URL, refreshing it in place if stale. Removes
    /// the entry and returns `nil` if the item can no longer be found at all (deleted, or
    /// moved off the volume).
    func resolve(_ entry: RecentVaultEntry) -> URL? {
        var isStale = false
        guard let url = Self.resolveBookmark(entry.bookmark, isStale: &isStale) else {
            remove(entry)
            return nil
        }

        if isStale, let refreshed = Self.makeBookmark(for: url) {
            var updated = entries
            if let index = updated.firstIndex(where: { $0.id == entry.id }) {
                updated[index].bookmark = refreshed
                updated[index].path = url.path
                entries = updated
                persist()
            }
        }

        return url
    }

    func remove(_ entry: RecentVaultEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - Bookmark creation/resolution

    /// Tries a security-scoped bookmark first — the forward-compatible choice if this app
    /// is ever sandboxed (see `security.md`'s known gap) — falling back to a plain
    /// bookmark, which is all an unsandboxed app actually needs and still survives the item
    /// being renamed/moved on the same volume, unlike a raw stored path string.
    private static func makeBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ bookmark: Data, isStale: inout Bool) -> URL? {
        if let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
