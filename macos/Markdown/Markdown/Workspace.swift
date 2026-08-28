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

    /// The file the editor is showing. Externally read-only — switch it with `selectFile(_:)`
    /// (or via `open(folder:)`/`open(file:)`/`close()`), which flush the previous file first.
    /// Not a plain stored property with `didSet` any more: flushing needs to await the
    /// WYSIWYG editor's own pending edit first (see `flushEditorPendingEdit`), and property
    /// observers can't be `async`.
    private(set) var selectedFile: URL?

    /// Set by the web view once its coordinator exists (see `MarkdownWebView`'s
    /// `registerFlushPendingEdit`). Asks the WYSIWYG editor to report its current text
    /// immediately, cancelling any pending debounce, before a flush reads `text` — otherwise
    /// switching files faster than the editor's own debounce could write stale content,
    /// silently dropping the last few keystrokes. `nil` before the web view has loaded, or in
    /// a context with no web view at all (e.g. a future headless test); every flush point
    /// below tolerates that by falling back to flushing `text` as it already stands, exactly
    /// the prior behavior.
    var flushEditorPendingEdit: (() async -> String?)?

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

    /// Commit id of the last successful create/rename/delete, `nil` for a folder create
    /// (git does not track empty folders, so there is nothing to commit) or when nothing has
    /// been mutated yet. Reserved for a future "Undo Last Change" File-menu item, mirroring
    /// `ChatViewModel.undo(commit:vaultRoot:)`.
    private(set) var lastChangeCommit: String?

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

    /// Persists which folders/files have been opened before, so they can be reopened via
    /// `openRecent(_:)` without going through `.fileImporter` again — see
    /// `.claude/plans/recent-vaults-plan.md`.
    let recentVaults = RecentVaultsStore()

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

    /// True when nothing is open at all — the state every launch starts in, since no
    /// vault is auto-reopened. Drives `ContentView`'s welcome screen.
    var isEmpty: Bool { root == nil && selectedFile == nil }

    /// Drives which content-area view `ContentView` shows. Defaults to `.markdown` when
    /// nothing is selected, matching the untitled placeholder editor shown today.
    var selectedFileKind: FileKind { selectedFile.map(FileKind.of) ?? .markdown }

    func open(folder url: URL) async {
        await flushPendingSaveAsync(to: selectedFile)
        watcher?.stop()
        watcher = nil
        vault = nil
        releaseScopedAccess()
        errorMessage = nil

        if url.startAccessingSecurityScopedResource() {
            scopedResource = url
        }
        recentVaults.record(url: url, isFolder: true)

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
    func open(file url: URL) async {
        if let root, VaultStore.relativePath(of: url, in: root.url) != nil {
            await performSelectFile(url)
            return
        }

        await flushPendingSaveAsync(to: selectedFile)
        watcher?.stop()
        watcher = nil
        vault = nil
        releaseScopedAccess()
        errorMessage = nil
        searchQuery = ""

        if url.startAccessingSecurityScopedResource() {
            scopedResource = url
        }
        recentVaults.record(url: url, isFolder: false)

        root = nil
        selectedFile = url
        loadSelectedFile()
    }

    /// Reopens a folder or file previously recorded in `recentVaults`, resolving its
    /// persisted bookmark back to a URL first. Reports and gives up if the bookmark can no
    /// longer be resolved (the item was deleted or moved off its volume) — `recentVaults`
    /// has already dropped the entry by the time this returns `nil`.
    func openRecent(_ entry: RecentVaultEntry) async {
        guard let url = recentVaults.resolve(entry) else {
            reportOpenFailure(RecentVaultUnavailableError(displayName: entry.displayName))
            return
        }

        if entry.isFolder {
            await open(folder: url)
        } else {
            await open(file: url)
        }
    }

    /// Closes whatever is open — a folder, or a single file — releasing its sandbox access.
    func close() async {
        await flushPendingSaveAsync(to: selectedFile)
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

    /// Switches to a different file within the currently open folder — the counterpart to
    /// `open(file:)`'s early-return branch, and the entry point for UI code (e.g. a `List`
    /// selection `Binding`, which can't `await` directly) that just wants to change what's
    /// shown. Flushes the previous file first, same as every other switch.
    func selectFile(_ url: URL?) {
        Task { @MainActor [weak self] in
            await self?.performSelectFile(url)
        }
    }

    private func performSelectFile(_ url: URL?) async {
        guard url != selectedFile else { return }
        await flushPendingSaveAsync(to: selectedFile)
        selectedFile = url
        loadSelectedFile()
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
    func open(dropped url: URL) async {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            await open(folder: url)
        } else if MarkdownFile.matches(url) {
            await open(file: url)
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
    func save() async {
        await flushPendingSaveAsync(to: selectedFile)
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

    /// Same as `flushPendingSave(to:)`, but first gives the WYSIWYG editor a chance to report
    /// a debounced edit that has not reached `text` yet, so a fast switch cannot silently
    /// drop the last few keystrokes. See `flushEditorPendingEdit`'s doc comment.
    private func flushPendingSaveAsync(to url: URL?) async {
        if let flush = flushEditorPendingEdit, let flushed = await flush(), flushed != text {
            text = flushed
        }
        flushPendingSave(to: url)
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

    /// Copies `data` into the vault's `assets` folder, opening (and, if this is the very
    /// first write anywhere in the folder, baselining) the vault the same way any other
    /// first edit would — see `vaultStore()`. Throws if there is no open folder to import
    /// into (e.g. a single file opened with no vault).
    func importAsset(filename: String, data: Data) throws -> (path: String, mime: String) {
        try vaultStore().importAsset(filename: filename, data: data)
    }

    /// Reads a vault file's raw bytes, for the web view's asset-serving fallback (e.g. an
    /// inline image dropped into a note). `nil` on any failure — including "no folder is
    /// open" — so a scheme-handler miss just 404s rather than surfacing an error dialog.
    ///
    /// Opens the vault on demand like `importAsset` above: rendering a note that references
    /// an asset can now cause the vault's first-open baseline commit to happen a little
    /// earlier than an actual edit would have. Accepted trade-off — an asset reference can
    /// only exist in a note in the first place because something already imported it
    /// through this same vault, so by the time this matters the vault has virtually always
    /// been opened already.
    func readAsset(_ path: String) -> (data: Data, mime: String)? {
        try? vaultStore().readAsset(path)
    }

    // MARK: - Sidebar file management

    /// Validates a name typed for a new note/folder or a rename, before anything reaches the
    /// vault. Returns a message to show the user, or `nil` if the name is fine. Deliberately
    /// narrow — everything else, in particular "already exists", is left to the vault, whose
    /// `VaultError` messages are already written to be read by a person.
    static func nameValidationError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name can't be empty." }
        if trimmed.contains("/") || trimmed.contains(":") { return "Name can't contain \"/\" or \":\"." }
        if trimmed == "." || trimmed == ".." { return "\"\(trimmed)\" isn't a valid name." }
        if trimmed.hasPrefix(".") { return "Name can't start with \".\" — it would become hidden." }
        return nil
    }

    /// Creates an empty note inside `directory`, named `Untitled.md`/`Untitled 2.md`/… —
    /// whatever is unused — so the sidebar can drop straight into inline rename, Finder-style,
    /// with no name prompt up front. Returns the new file's URL on success.
    @discardableResult
    func createNote(in directory: URL) async -> URL? {
        await save()
        do {
            let name = availableName(base: "Untitled", extension: "md", in: directory)
            let newURL = directory.appendingPathComponent(name)
            let relative = try vaultRelative(newURL)
            try rejectIfGitInternals(relative)
            lastChangeCommit = try vaultStore().createFile(relative, contents: "")
            revealAfterMutation(in: directory)
            errorMessage = nil
            selectFile(newURL)
            return newURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Creates an empty folder inside `directory`, named `New Folder`/`New Folder 2`/… —
    /// same auto-naming as `createNote(in:)`. A `nil` commit id from the vault call is
    /// expected, not a failure — git does not track empty folders. Returns the new folder's
    /// URL on success (regardless of whether a commit was made).
    @discardableResult
    func createFolder(in directory: URL) async -> URL? {
        await save()
        do {
            let name = availableName(base: "New Folder", extension: nil, in: directory)
            let newURL = directory.appendingPathComponent(name)
            let relative = try vaultRelative(newURL)
            try rejectIfGitInternals(relative)
            lastChangeCommit = try vaultStore().createFolder(relative)
            revealAfterMutation(in: directory)
            errorMessage = nil
            return newURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The next unused Finder-style name in `directory` — `"New Folder"`, `"New Folder 2"`, …
    /// (or `"Untitled.md"`, `"Untitled 2.md"`, … when `extension` is given) — checked against
    /// whatever children are currently loaded for that directory. If the directory has never
    /// been expanded there is nothing loaded to check against yet; a collision there is rare
    /// and the vault's own "already exists" rejection is the backstop.
    private func availableName(base: String, extension ext: String?, in directory: URL) -> String {
        let existing = Set((node(for: directory)?.children ?? []).map(\.name))
        func candidate(_ n: Int) -> String {
            let label = n == 1 ? base : "\(base) \(n)"
            return ext.map { "\(label).\($0)" } ?? label
        }
        var n = 1
        while existing.contains(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// Renames or moves-in-place a file or folder to `newName`, kept in its current parent.
    @discardableResult
    func rename(_ url: URL, to newName: String) async -> Bool {
        await save()
        do {
            if let reason = Self.nameValidationError(newName) { throw SidebarMutationError.invalidName(reason) }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fromRelative = try vaultRelative(url)
            try rejectIfGitInternals(fromRelative)
            let newURL = url.deletingLastPathComponent().appendingPathComponent(trimmed)
            let toRelative = try vaultRelative(newURL)
            try rejectIfGitInternals(toRelative)
            // Captured before the rename touches the tree: `refresh()` below matches old and
            // new contents by URL, so the renamed node itself never matches (its URL just
            // changed) and would otherwise come back collapsed with its whole loaded subtree
            // discarded, even though nothing on disk changed but the name.
            let preserved = node(for: url)
            lastChangeCommit = try vaultStore().move(from: fromRelative, to: toRelative)
            root?.refresh()
            if let preserved {
                node(for: newURL)?.adoptSubtree(from: preserved)
            }
            repointSelection(from: url, to: newURL)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes a file or folder — recursively for a folder, per `markdown_vault`'s `delete`.
    @discardableResult
    func delete(_ url: URL) async -> Bool {
        await save()
        do {
            let relative = try vaultRelative(url)
            try rejectIfGitInternals(relative)
            lastChangeCommit = try vaultStore().delete(relative)
            clearSelectionIfAffected(by: url)
            root?.refresh()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Vault-relative path of `url`, or a readable error when there is no open folder (a
    /// single file, or nothing open) or `url` falls outside it.
    private func vaultRelative(_ url: URL) throws -> String {
        guard let relative = relativePath(of: url) else {
            throw SidebarMutationError.outsideFolder
        }
        return relative
    }

    /// `.git` is reachable through `confine::resolve_in` like any other vault path — nothing
    /// on the Rust side singles it out — so this is the only thing stopping a rename or
    /// delete issued from the tree from touching the vault's own history. The tree also never
    /// lists dot-entries (`FileNode.contents(of:)`), so this is belt-and-braces.
    private func rejectIfGitInternals(_ relative: String) throws {
        if relative == ".git" || relative.hasPrefix(".git/") {
            throw SidebarMutationError.gitInternals
        }
    }

    /// After creating something inside `directory`, the merging `refresh()` alone will not
    /// reveal it if `directory` has never been expanded — `refresh()` only recurses where
    /// children are already loaded, by design. Force that one directory open in that case;
    /// otherwise a plain refresh is enough to pick up the new entry.
    private func revealAfterMutation(in directory: URL) {
        root?.refresh()
        guard let target = node(for: directory), target.children == nil else { return }
        target.loadChildren()
        target.isExpanded = true
    }

    private func node(for url: URL, in start: FileNode? = nil) -> FileNode? {
        guard let start = start ?? root else { return nil }
        if start.url == url { return start }
        for child in start.children ?? [] {
            if let found = node(for: url, in: child) { return found }
        }
        return nil
    }

    /// Moves the selection along with a rename — of the file itself, or of an ancestor
    /// folder the selected file lives inside.
    private func repointSelection(from oldURL: URL, to newURL: URL) {
        guard let selectedFile else { return }
        let oldPath = oldURL.standardizedFileURL.path
        let selectedPath = selectedFile.standardizedFileURL.path

        if selectedPath == oldPath {
            selectFile(newURL)
        } else if selectedPath.hasPrefix(oldPath + "/") {
            let suffix = selectedPath.dropFirst(oldPath.count)
            selectFile(URL(fileURLWithPath: newURL.standardizedFileURL.path + suffix))
        }
    }

    /// Clears the selection when the deleted item is, or contains, the selected file —
    /// resetting the buffer *before* `selectFile(nil)` so the debounced-save machinery that
    /// runs when the selection actually changes has nothing left to write back to the path
    /// that is about to stop existing.
    private func clearSelectionIfAffected(by url: URL) {
        guard let selectedFile else { return }
        let deletedPath = url.standardizedFileURL.path
        let selectedPath = selectedFile.standardizedFileURL.path
        guard selectedPath == deletedPath || selectedPath.hasPrefix(deletedPath + "/") else { return }

        autosaveTask?.cancel()
        autosaveTask = nil
        hasUnsavedChanges = false
        text = Self.untitledText
        selectFile(nil)
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
        switch FileKind.of(url) {
        case .image, .pdf:
            // Read-only viewers load their own bytes straight from `url` (see ImageViewer/
            // PDFViewerView) — leave `text`/autosave/hasUnsavedChanges untouched.
            errorMessage = nil
            return
        case .markdown, .plainText:
            break
        }
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

/// A create/rename/delete issued from the sidebar was refused before it ever reached the
/// vault. See `Workspace`'s "Sidebar file management" section.
private enum SidebarMutationError: LocalizedError {
    case outsideFolder
    case gitInternals
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .outsideFolder: "That item is outside the open folder."
        case .gitInternals: "That is part of this folder's history and can't be changed here."
        case .invalidName(let reason): reason
        }
    }
}

/// A recent-vaults entry's bookmark could not be resolved to a URL — the item was likely
/// deleted or moved off its volume since it was last opened.
private struct RecentVaultUnavailableError: LocalizedError {
    let displayName: String
    var errorDescription: String? { "Could not reopen \(displayName). It may have been moved or deleted." }
}
