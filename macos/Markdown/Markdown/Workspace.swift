//
//  Workspace.swift
//  Markdown
//
//  The opened folder, the file shown in the editor, and the sandbox access that
//  keeps both reachable.
//
//  Edits are saved for you: typing schedules a debounced write, and switching files or
//  closing the folder flushes first. When a folder is open, every change goes through
//  `VaultStore`, so it is committed to the vault's history and can be undone. A file opened
//  on its own has no vault to write through — the sandbox grants access to exactly the item
//  the user picked or dropped, not its enclosing folder, so there is nothing to open a vault
//  *at* — and is written directly instead. See `open(file:)`.
//

import Foundation
import Observation

@Observable
final class Workspace {
    static let untitledText = "Hello, world!"

    private(set) var root: FileNode?

    /// The file the editor is showing. Setting it reads that file from disk.
    var selectedFile: URL? {
        didSet {
            guard selectedFile != oldValue else { return }
            // `text` still holds the previous file's contents here, so flush before loading.
            flushPendingSave(to: oldValue)
            loadSelectedFile()
        }
    }

    var text = Workspace.untitledText {
        didSet {
            guard text != oldValue else { return }
            scheduleAutosave()
        }
    }

    /// True while the editor holds changes that are not on disk yet.
    private(set) var hasUnsavedChanges = false

    /// Set when the last open attempt failed; shown under the sidebar tree.
    private(set) var errorMessage: String?

    /// Typed into the toolbar's search field; drives `searchHits`.
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            restartSearch()
        }
    }

    private(set) var searchHits: [SearchHit] = []
    private(set) var isSearching = false

    var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Held so the sandbox keeps letting us reach whatever was opened — a folder's full
    /// subtree, or (when there is no folder) just the one file.
    private var scopedResource: URL?

    /// The in-flight search, cancelled whenever the query changes again.
    private var searchTask: Task<Void, Never>?

    /// Opened on the first write rather than on open, so browsing a folder leaves no trace —
    /// in particular, no `.git` directory appears until something actually changes.
    private var vault: VaultStore?

    /// The pending debounced save, cancelled by each further keystroke.
    private var autosaveTask: Task<Void, Never>?

    /// Watches for changes made outside the app — by an MCP client, or another editor.
    private var watcher: VaultWatcher?

    var folderName: String? { root?.name }

    var documentTitle: String { selectedFile?.lastPathComponent ?? "Untitled" }

    /// True once a file is open but there is no folder behind it — no history, no search,
    /// no assistant for it, just direct reading and writing of that one file.
    var isSingleFile: Bool { root == nil && selectedFile != nil }

    func open(folder url: URL) {
        flushPendingSave(to: selectedFile)
        watcher?.stop()
        watcher = nil
        vault = nil
        releaseScopedAccess()
        errorMessage = nil

        if url.startAccessingSecurityScopedResource() {
            scopedResource = url
        }

        let node = FileNode(url: url, isDirectory: true)
        node.loadChildren()
        node.isExpanded = true

        root = node
        selectedFile = nil
        text = Self.untitledText
        restartSearch()

        watcher = VaultWatcher(root: url) { [weak self] changed in
            self?.absorbExternalChanges(changed)
        }
    }

    /// Opens a single file with no folder context.
    ///
    /// Its enclosing folder is deliberately *not* opened as a vault: a file the user picked
    /// or dropped only grants sandbox access to that exact item, not its parent directory, so
    /// there is nothing to browse, search, or hand to the assistant — only the file itself,
    /// read and written directly.
    ///
    /// If `url` already lives inside the currently open folder, it is simply selected there
    /// instead, keeping the vault (and its history, search, and assistant) intact rather than
    /// discarding it for a file that already has all of that.
    func open(file url: URL) {
        if let root, VaultStore.relativePath(of: url, in: root.url) != nil {
            selectedFile = url
            return
        }

        flushPendingSave(to: selectedFile)
        watcher?.stop()
        watcher = nil
        vault = nil
        releaseScopedAccess()
        errorMessage = nil
        searchQuery = ""

        if url.startAccessingSecurityScopedResource() {
            scopedResource = url
        }

        root = nil
        selectedFile = url
    }

    /// Closes whatever is open — a folder, or a single file — releasing its sandbox access.
    func close() {
        flushPendingSave(to: selectedFile)
        watcher?.stop()
        watcher = nil
        vault = nil
        releaseScopedAccess()
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchHits = []
        isSearching = false
        root = nil
        selectedFile = nil
        errorMessage = nil
        text = Self.untitledText
    }

    /// Debounced so a burst of keystrokes only reads the folder once.
    private func restartSearch() {
        searchTask?.cancel()

        guard let root, isSearchActive else {
            searchTask = nil
            searchHits = []
            isSearching = false
            return
        }

        let query = searchQuery
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            let hits = await FolderSearch.run(root: root.url, query: query)
            guard !Task.isCancelled else { return }

            self?.searchHits = hits
            self?.isSearching = false
        }
    }

    func reportOpenFailure(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    /// Routes a drag-and-dropped item to whichever open method fits it: a folder opens as a
    /// vault, a Markdown file opens on its own. Anything else is reported, not silently
    /// ignored — a drop that visibly did nothing reads as a bug. Shared by every drop target
    /// in the app (the window body, the sidebar's toolbar) so they behave identically.
    func open(dropped url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            open(folder: url)
        } else if MarkdownFile.matches(url) {
            open(file: url)
        } else {
            reportOpenFailure(UnsupportedDropError())
        }
    }

    // MARK: - Changes from outside the app

    /// Folds in changes another writer made: refresh the tree, and reload the open file when
    /// doing so cannot lose anything.
    private func absorbExternalChanges(_ changed: [URL]) {
        root?.refresh()

        // A search over the folder is now stale.
        if isSearchActive {
            restartSearch()
        }

        guard let selectedFile,
              changed.contains(where: {
                  $0.standardizedFileURL.path == selectedFile.standardizedFileURL.path
              })
        else {
            return
        }

        // Never overwrite what the person is in the middle of typing. Their copy stays; the
        // conflict is surfaced instead of being resolved by whoever wrote last.
        guard !hasUnsavedChanges else {
            errorMessage = "\(selectedFile.lastPathComponent) also changed outside the app. "
                + "Your unsaved edits are still here; saving will overwrite the other change."
            return
        }
        loadSelectedFile()
    }

    // MARK: - Saving

    /// Writes the buffer now, if it has changes. Safe to call when there is nothing to do.
    func save() {
        flushPendingSave(to: selectedFile)
    }

    private func scheduleAutosave() {
        // The untitled scratch buffer has nowhere to go until a file is chosen.
        guard selectedFile != nil else { return }
        hasUnsavedChanges = true

        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.flushPendingSave(to: self?.selectedFile)
        }
    }

    /// Writes the current buffer to `url`, which may be a file we have just navigated away
    /// from — hence the explicit argument rather than reading `selectedFile`.
    private func flushPendingSave(to url: URL?) {
        autosaveTask?.cancel()
        autosaveTask = nil

        guard hasUnsavedChanges, let url else { return }

        do {
            if let relative = relativePath(of: url) {
                try vaultStore().write(relative, contents: text)
            } else {
                // No vault open at this URL — a single file with no folder — so there is
                // nothing to route through `VaultStore`. Write it directly instead.
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            hasUnsavedChanges = false
            errorMessage = nil
        } catch {
            // Keep `hasUnsavedChanges` set: the next keystroke or switch will try again.
            errorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Opens the vault on demand. See `vault` for why this is not done when the folder opens.
    private func vaultStore() throws -> VaultStore {
        if let vault { return vault }
        guard let root = root?.url else { throw VaultError.malformedReply }
        let opened = try VaultStore(root: root)
        vault = opened
        return opened
    }

    private func relativePath(of url: URL) -> String? {
        guard let root = root?.url else { return nil }
        return VaultStore.relativePath(of: url, in: root)
    }

    private func loadSelectedFile() {
        guard let url = selectedFile else { return }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            // Assigning `text` scheduled a save; the file is what is on disk, so cancel it.
            autosaveTask?.cancel()
            autosaveTask = nil
            hasUnsavedChanges = false
            errorMessage = nil
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func releaseScopedAccess() {
        scopedResource?.stopAccessingSecurityScopedResource()
        scopedResource = nil
    }
}

/// Only Markdown files and folders can be opened by dropping; anything else is reported
/// through the same error path a failed file picker would use.
private struct UnsupportedDropError: LocalizedError {
    var errorDescription: String? { "Only folders and Markdown files can be opened here." }
}
