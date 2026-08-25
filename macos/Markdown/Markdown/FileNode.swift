//
//  FileNode.swift
//  Markdown
//
//  Model behind the sidebar folder tree.
//

import Foundation
import Observation
import UniformTypeIdentifiers

/// File kinds the sidebar shows. Everything else is hidden, so a folder of mixed
/// content reads as a list of notes rather than a file browser.
nonisolated enum MarkdownFile {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "text", "txt"]

    static func matches(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// For the "Open File…" panel. The system synthesizes a type for any extension it does
    /// not already recognise (`mdx`, `mkd`, …), so this reliably filters to exactly these.
    static let contentTypes: [UTType] = extensions.compactMap { UTType(filenameExtension: $0) }
}

/// One row of the folder tree.
///
/// A directory reads its contents the first time it is expanded, so opening a folder
/// with a deep hierarchy only touches the levels that are actually on screen.
@Observable
final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    private(set) var children: [FileNode]?
    var isExpanded = false

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Fails when `url` cannot be inspected, e.g. a symlink to somewhere unreadable.
    convenience init?(url: URL) {
        guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        else {
            return nil
        }
        self.init(url: url, isDirectory: isDirectory)
    }

    /// Reads the directory once; later calls do nothing.
    func loadChildren() {
        guard isDirectory, children == nil else { return }
        children = Self.contents(of: url)
    }

    /// Drops the cached contents so the next expansion re-reads the directory.
    func reload() {
        children = nil
        loadChildren()
    }

    /// Re-reads the directory, keeping the node objects that are still there.
    ///
    /// Merging rather than rebuilding is what makes external changes bearable: `reload()`
    /// replaces every child instance, so an agent touching one file would collapse every
    /// expanded folder in the tree. Directories that were never expanded stay unread.
    func refresh() {
        guard isDirectory, let existing = children else { return }

        let kept = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        children = Self.contents(of: url).map { fresh in
            guard let previous = kept[fresh.url], previous.isDirectory == fresh.isDirectory else {
                return fresh
            }
            return previous
        }

        // Only recurse where contents are already on screen.
        for child in children ?? [] where child.isDirectory && child.children != nil {
            child.refresh()
        }
    }

    @MainActor
    private static func contents(of directory: URL) -> [FileNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .compactMap(FileNode.init(url:))
            .filter { $0.isDirectory || MarkdownFile.matches($0.url) }
            .sorted { lhs, rhs in
                lhs.isDirectory == rhs.isDirectory
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.isDirectory
            }
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
