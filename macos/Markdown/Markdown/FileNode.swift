//
//  FileNode.swift
//  Markdown
//
//  Model behind the sidebar folder tree.
//

import Foundation
import Observation
import UniformTypeIdentifiers

/// Markdown-flavored file kinds — used for the "Open File…" panel and for routing a
/// dropped file to `open(file:)` vs. reporting it unsupported. The sidebar tree itself
/// hides dot-prefixed entries (`.git`, `.gitignore`, …, see `FileNode.contents(of:)`); of
/// what remains, `SidebarFilter` decides whether non-Markdown files are shown too.
nonisolated enum MarkdownFile {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "text", "txt"]

    static func matches(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// For the "Open File…" panel. The system synthesizes a type for any extension it does
    /// not already recognise (`mdx`, `mkd`, …), so this reliably filters to exactly these.
    static let contentTypes: [UTType] = extensions.compactMap { UTType(filenameExtension: $0) }
}

/// Raster image extensions the sidebar treats as images (for the row icon, and later a
/// zoomable viewer — see `.claude/plans/file-type-viewers-plan.md`). Deliberately excludes
/// `svg` (XML/text, not a format `NSImage` rasterizes uniformly with the others) and `ico`
/// (niche, not worth a special case).
nonisolated enum ImageFile {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
}

/// Coarse file-type classification, used today for the sidebar row icon and planned to
/// drive the content-area viewer next (`.claude/plans/file-type-viewers-plan.md`).
nonisolated enum FileKind {
    case markdown, image, pdf, plainText

    static func of(_ url: URL) -> FileKind {
        if MarkdownFile.matches(url) { return .markdown }
        if ImageFile.extensions.contains(url.pathExtension.lowercased()) { return .image }
        if url.pathExtension.lowercased() == "pdf" { return .pdf }
        return .plainText
    }
}

/// Whether the sidebar tree shows every non-hidden file, or Markdown files only. Folders are
/// always shown under both settings — hiding a folder with no Markdown inside would require
/// eagerly walking the whole tree, defeating `FileNode`'s load-on-expand design, and would
/// make a folder the user just created vanish instantly.
nonisolated enum SidebarFilter: String, CaseIterable, Identifiable {
    case all
    case markdownOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Files"
        case .markdownOnly: "Markdown Only"
        }
    }

    func shows(_ node: FileNode) -> Bool {
        node.isDirectory || self == .all || MarkdownFile.matches(node.url)
    }
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

    /// The children a `SidebarFilter` lets through — shared by the root section and every
    /// recursive row so they always agree on what "visible" means.
    func visibleChildren(_ filter: SidebarFilter) -> [FileNode] {
        (children ?? []).filter(filter.shows)
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

    /// Rebuilds this node's subtree from `other`'s already-loaded one, translating every
    /// descendant URL from `other`'s location to this node's.
    ///
    /// Needed after a rename: `refresh()` matches old and new contents by URL, so a renamed
    /// folder's new URL never matches its old entry — it comes back as a brand-new node with
    /// `children == nil` and `isExpanded == false`, silently collapsing whatever was loaded
    /// underneath it even though nothing on disk actually changed except the name. Calling
    /// this on that new node, passing the old (pre-rename) node, restores the same expansion
    /// and loaded contents without re-reading the disk. `url` is `let`, so descendants can't
    /// be relocated in place — this reconstructs them instead.
    func adoptSubtree(from other: FileNode) {
        isExpanded = other.isExpanded
        guard let otherChildren = other.children else { return }
        children = otherChildren.map { child in
            let relocated = FileNode(
                url: url.appendingPathComponent(child.url.lastPathComponent),
                isDirectory: child.isDirectory
            )
            relocated.adoptSubtree(from: child)
            return relocated
        }
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
            options: []
        )) ?? []

        return urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap(FileNode.init(url:))
            .sorted { lhs, rhs in
                lhs.isDirectory == rhs.isDirectory
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.isDirectory
            }
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
