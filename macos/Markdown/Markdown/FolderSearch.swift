//
//  FolderSearch.swift
//  Markdown
//
//  Searches the open folder by file name and file contents.
//
//  Runs off the main actor: a folder of notes can hold thousands of files, and reading
//  them must not stall typing in the search field.
//

import Foundation

/// One matching file, with the lines that matched.
nonisolated struct SearchHit: Identifiable, Sendable {
    let url: URL
    /// True when the file's name matched, which sorts it above content-only matches.
    let nameMatched: Bool
    /// Matching lines, trimmed for display.
    let snippets: [String]

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

nonisolated enum FolderSearch {
    /// Stops one enormous file from stalling a search.
    private static let maxFileBytes = 4 << 20

    /// Matching lines kept per file.
    private static let maxSnippetsPerFile = 3

    /// Enough to fill the sidebar many times over; beyond this the query is too broad.
    private static let maxHits = 200

    private static let snippetLimit = 160

    /// Finds files whose name or contents contain `query`.
    ///
    /// Cooperatively cancellable: a new keystroke cancels the task running this.
    static func run(root: URL, query: String) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var hits: [SearchHit] = []

        // Enumerated up front: a directory enumerator cannot be iterated from an async context.
        for url in candidates(under: root) {
            if Task.isCancelled { return [] }
            guard hits.count < maxHits else { break }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }

            let nameMatched = url.lastPathComponent.localizedCaseInsensitiveContains(needle)
            let size = values?.fileSize ?? 0
            let snippets = size <= maxFileBytes ? matchingLines(in: url, needle: needle) : []

            if nameMatched || !snippets.isEmpty {
                hits.append(SearchHit(url: url, nameMatched: nameMatched, snippets: snippets))
            }
        }

        // Name matches first, then alphabetically, so results do not jump around.
        return hits.sorted { lhs, rhs in
            lhs.nameMatched == rhs.nameMatched
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : lhs.nameMatched
        }
    }

    /// Every Markdown file under `root`, deepest paths included.
    private static func candidates(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        guard let urls = enumerator?.allObjects as? [URL] else { return [] }
        return urls.filter(MarkdownFile.matches)
    }

    private static func matchingLines(in url: URL, needle: String) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var snippets: [String] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.localizedCaseInsensitiveContains(needle) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            snippets.append(String(trimmed.prefix(snippetLimit)))
            if snippets.count == maxSnippetsPerFile { break }
        }
        return snippets
    }
}
