//
//  SidebarView.swift
//  Markdown
//
//  The folder tree, the search results that replace it while searching, and the account
//  row pinned to the bottom.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The create/rename/delete callbacks threaded down through the tree recursion, so every
/// `FileTreeRow` can drive `SidebarView`'s state without holding a `Workspace` of its own.
///
/// Create and rename are both inline, Finder-style: `beginRename` just puts a row into edit
/// mode (`SidebarView.editingNodeID`); the actual vault call happens on `commitRename`, once
/// the user accepts a name. Creation goes through `SidebarView.createNewNote`/
/// `createNewFolder` directly, not through this struct — there is no row to begin editing
/// until the new item exists.
private struct FileTreeRowActions {
    let newNote: (URL) -> Void
    let newFolder: (URL) -> Void
    let beginRename: (FileNode) -> Void
    let commitRename: (FileNode, String) -> Void
    let cancelRename: () -> Void
    let delete: (FileNode) -> Void
}

struct SidebarView: View {
    @Bindable var workspace: Workspace
    let account: Account
    let openFolder: () -> Void
    let openFile: () -> Void
    let openSettings: () -> Void
    let openLogin: () -> Void
    let openChat: () -> Void

    @State private var isOpenDropTargeted = false

    @AppStorage(PreferenceKey.sidebarFilter) private var sidebarFilter = SidebarFilter.all

    /// The row currently showing an inline `TextField` instead of its name — either a
    /// just-created item (dropped straight into rename, Finder-style) or an existing one
    /// being renamed via the context menu. `nil` means every row shows plain text.
    @State private var editingNodeID: URL?
    @State private var pendingDelete: FileNode?

    private var fileTreeActions: FileTreeRowActions {
        FileTreeRowActions(
            newNote: createNewNote(in:),
            newFolder: createNewFolder(in:),
            beginRename: { editingNodeID = $0.url },
            commitRename: commitRename,
            cancelRename: { editingNodeID = nil },
            delete: { pendingDelete = $0 }
        )
    }

    /// Where a create command lands, per the row it was invoked from:
    /// - a **folder** row → inside that folder
    /// - a **file** row → alongside it, in its parent directory
    /// - no row at all (root header, empty area, toolbar, File menu) → the parent of the
    ///   selected file if there is one, else the vault root.
    ///
    /// `nil` whenever there is no open folder to create inside — a single file, or nothing
    /// open at all — which disables every affordance built on top of this.
    private func targetDirectory(for node: FileNode?) -> URL? {
        guard workspace.root != nil else { return nil }
        if let node {
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }
        if let selected = workspace.selectedFile {
            return selected.deletingLastPathComponent()
        }
        return workspace.root?.url
    }

    /// Creates the note immediately, with an auto-generated name, and drops straight into
    /// inline rename on the new row — no name prompt up front, matching Finder.
    private func createNewNote(in directory: URL) {
        Task { @MainActor in
            if let url = await workspace.createNote(in: directory) {
                editingNodeID = url
            }
        }
    }

    private func createNewFolder(in directory: URL) {
        Task { @MainActor in
            if let url = await workspace.createFolder(in: directory) {
                editingNodeID = url
            }
        }
    }

    /// Commits an inline edit: renames only if the trimmed name is non-empty and actually
    /// changed — covers "created it, then just clicked away without typing anything" and "hit
    /// Return with an empty field" without bothering the vault (or the user) about either.
    private func commitRename(_ node: FileNode, to name: String) {
        editingNodeID = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        Task { @MainActor in await workspace.rename(node.url, to: trimmed) }
    }

    /// `Workspace.selectedFile` is read-only externally (switching it needs to flush the
    /// WYSIWYG editor's pending edit first, which is `async`, and a `List` selection
    /// `Binding`'s `set` can't `await`) — `selectFile(_:)` is the synchronous entry point
    /// that does the `async` work internally.
    private var selectedFileBinding: Binding<URL?> {
        Binding(get: { workspace.selectedFile }, set: { workspace.selectFile($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.isSearchActive {
                searchResults
            } else if let root = workspace.root {
                List(selection: selectedFileBinding) {
                    Section {
                        ForEach(root.visibleChildren(sidebarFilter)) { child in
                            AnyView(FileTreeRow(
                                node: child,
                                filter: sidebarFilter,
                                editingNodeID: editingNodeID,
                                actions: fileTreeActions
                            ))
                        }
                    } header: {
                        Text(root.name)
                            .contextMenu { rootContextMenu(root) }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu {
                    rootContextMenu(root)
                }
                .onKeyPress(.return) {
                    guard editingNodeID == nil, let selected = workspace.selectedFile else { return .ignored }
                    editingNodeID = selected
                    return .handled
                }
            } else if workspace.isSingleFile {
                singleFileState
            } else {
                emptyState
            }

            if let message = workspace.errorMessage {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            accountRow
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Open Folder…", action: openFolder)
                    Button("Open File…", action: openFile)
                    if !workspace.recentVaults.entries.isEmpty {
                        Divider()
                        Menu("Open Recent") {
                            ForEach(workspace.recentVaults.entries) { entry in
                                Button(entry.displayName) {
                                    Task { @MainActor in await workspace.openRecent(entry) }
                                }
                            }
                            Divider()
                            Button("Clear Menu") { workspace.recentVaults.clear() }
                        }
                    }
                } label: {
                    Label("Open", systemImage: "folder.badge.plus")
                }
                .help("Open a folder or a single Markdown file — or drag one here")
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOpenDropTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .onDrop(of: [.fileURL], isTargeted: $isOpenDropTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in await workspace.open(dropped: url) }
                    }
                    return true
                }
            }
            ToolbarItem {
                Menu {
                    let directory = targetDirectory(for: nil)
                    Button("New Note") { if let directory { createNewNote(in: directory) } }
                        .disabled(directory == nil)
                    Button("New Folder") { if let directory { createNewFolder(in: directory) } }
                        .disabled(directory == nil)
                    Divider()
                    Picker("Show", selection: $sidebarFilter) {
                        ForEach(SidebarFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("Create a new note or folder, or change what the tree shows")
            }
            ToolbarItem {
                Button("Assistant", systemImage: "sparkles") { openChat() }
                    .help("Ask the assistant about this folder")
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \"\($0.name)\"?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { node in
            Button("Delete", role: .destructive) {
                let url = node.url
                pendingDelete = nil
                Task { @MainActor in await workspace.delete(url) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { node in
            Text(node.isDirectory
                 ? "\"\(node.name)\" and everything inside it will be deleted. This is recorded in the folder's history and can be recovered from there."
                 : "\"\(node.name)\" will be deleted. This is recorded in the folder's history and can be recovered from there.")
        }
        .focusedSceneValue(\.newNoteAction) {
            if let directory = targetDirectory(for: nil) { createNewNote(in: directory) }
        }
        .focusedSceneValue(\.newFolderAction) {
            if let directory = targetDirectory(for: nil) { createNewFolder(in: directory) }
        }
    }

    @ViewBuilder
    private func rootContextMenu(_ root: FileNode) -> some View {
        if let directory = targetDirectory(for: nil) {
            Button("New Note") { createNewNote(in: directory) }
            Button("New Folder") { createNewFolder(in: directory) }
            Divider()
        }
        Picker("Show", selection: $sidebarFilter) {
            ForEach(SidebarFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        Divider()
        Button("Refresh") { root.reload() }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        if workspace.searchHits.isEmpty {
            ContentUnavailableView {
                Label(workspace.isSearching ? "Searching…" : "No Results", systemImage: "magnifyingglass")
            } description: {
                if !workspace.isSearching {
                    Text("Nothing matches \"\(workspace.searchQuery)\".")
                }
            }
        } else {
            List(selection: selectedFileBinding) {
                Section {
                    ForEach(workspace.searchHits) { hit in
                        SearchHitRow(hit: hit).tag(hit.url)
                    }
                } header: {
                    Text(workspace.isSearching
                         ? "Searching…"
                         : "^[\(workspace.searchHits.count) result](inflect: true)")
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Account

    private var accountRow: some View {
        Menu {
            if account.isLoggedIn {
                Button("Settings…", action: openSettings)
                Divider()
                Button("Log Out") { account.logOut() }
            } else {
                Button("Log In…", action: openLogin)
                Button("Settings…", action: openSettings)
            }
        } label: {
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.isLoggedIn ? account.fullName : "Not signed in")
                        .lineLimit(1)
                    if account.isLoggedIn, !account.email.isEmpty {
                        Text(account.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(account.isLoggedIn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            if account.isLoggedIn {
                Text(account.initials)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Folder Open", systemImage: "folder")
        } description: {
            Text("Open a folder to browse its Markdown files, or open a single file — you can also drag either onto the window.")
        } actions: {
            Button("Open Folder…") { openFolder() }
            Button("Open File…") { openFile() }
        }
    }

    /// Shown when a single file is open with no folder behind it. Deliberately not the same
    /// as `emptyState`: a file *is* open, in the editor, so saying "No Folder Open" here would
    /// read as if nothing had happened.
    private var singleFileState: some View {
        ContentUnavailableView {
            Label(workspace.documentTitle, systemImage: "doc.text")
        } description: {
            Text("Opened on its own — no folder, so search and the assistant aren't available for it.")
        } actions: {
            Button("Open Folder…") { openFolder() }
        }
    }
}

/// One search result: the file name, then the lines that matched.
private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(hit.name, systemImage: "doc.text")
            ForEach(Array(hit.snippets.enumerated()), id: \.offset) { _, snippet in
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 1)
    }
}

/// One tree row.
///
/// The recursion is erased through `AnyView` because a `View` whose body contains its own
/// type has no finite static type.
private struct FileTreeRow: View {
    @Bindable var node: FileNode
    let filter: SidebarFilter
    let editingNodeID: URL?
    let actions: FileTreeRowActions

    private var isEditing: Bool { editingNodeID == node.url }

    var body: some View {
        if node.isDirectory {
            directory
        } else {
            rowLabel
                .tag(node.url)
                .contextMenu { fileContextMenu }
        }
    }

    /// The row's icon plus either its name or, while `isEditing`, an inline `TextField` in
    /// its place — shared between the file row and the folder `DisclosureGroup`'s label, so
    /// a folder can be renamed in place exactly like a file.
    @ViewBuilder
    private var rowLabel: some View {
        if isEditing {
            HStack {
                fileIcon
                InlineNameField(
                    initialName: baseNameForEditing,
                    hiddenExtension: hiddenExtension,
                    onCommit: { actions.commitRename(node, $0) },
                    onCancel: actions.cancelRename
                )
            }
        } else {
            Label {
                Text(node.name)
            } icon: {
                fileIcon
            }
        }
    }

    /// `.md` is the extension almost every note has and almost nobody wants to type or see
    /// while renaming — hidden here and restored on commit if the user doesn't type a
    /// different one. Other extensions (`.txt`, images, …) are left alone: unlike `.md`,
    /// there's no single obvious "this is what you meant" default to restore, so those stay
    /// visible and editable exactly as before.
    private var hiddenExtension: String? {
        guard !node.isDirectory, node.url.pathExtension.lowercased() == "md" else { return nil }
        return node.url.pathExtension
    }

    private var baseNameForEditing: String {
        guard let ext = hiddenExtension else { return node.name }
        return String(node.name.dropLast(ext.count + 1))
    }

    private var directory: some View {
        DisclosureGroup(isExpanded: $node.isExpanded) {
            ForEach(node.visibleChildren(filter)) { child in
                AnyView(FileTreeRow(node: child, filter: filter, editingNodeID: editingNodeID, actions: actions))
            }
        } label: {
            rowLabel
        }
        .onChange(of: node.isExpanded, initial: true) { _, isExpanded in
            if isExpanded { node.loadChildren() }
        }
        .contextMenu {
            folderContextMenu
        }
    }

    @ViewBuilder
    private var folderContextMenu: some View {
        Button("New Note") { actions.newNote(node.url) }
        Button("New Folder") { actions.newFolder(node.url) }
        Divider()
        Button("Rename") { actions.beginRename(node) }
        Button("Delete", role: .destructive) { actions.delete(node) }
        Divider()
        Button("Refresh") { node.reload() }
    }

    @ViewBuilder
    private var fileContextMenu: some View {
        let parent = node.url.deletingLastPathComponent()
        Button("New Note") { actions.newNote(parent) }
        Button("New Folder") { actions.newFolder(parent) }
        Divider()
        Button("Rename") { actions.beginRename(node) }
        Button("Delete", role: .destructive) { actions.delete(node) }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }

    /// The real system icon — Finder's own colors and per-type glyph (including the
    /// standard blue folder icon), via `NSWorkspace`, rather than a hand-picked SF Symbol.
    private var fileIcon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
    }
}

/// A single editable name field, dropped in place of a row's `Text` — used both right after
/// creating a note/folder and for an explicit "Rename" — mirroring Finder's inline rename.
///
/// `Return` or losing focus (clicking elsewhere) commits the typed name; `Escape` reverts to
/// `initialName` without calling `onCommit` at all. `isResolved` guards against firing twice:
/// pressing Escape both calls `onCancel` directly *and* triggers the focus-loss `onChange`
/// below (removing the field from the view hierarchy defocuses it), so the second caller must
/// be a no-op.
private struct InlineNameField: View {
    let initialName: String
    /// When non-`nil` (only for `.md` notes — see `FileTreeRow.hiddenExtension`),
    /// `initialName` already has this extension stripped for display; `resolve(commit:)`
    /// restores it on commit unless the user typed a different extension of their own.
    let hiddenExtension: String?
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool
    @State private var isResolved = false

    /// A fresh row (just created, or just selected via "Rename") is also mid selection-change
    /// in the `List` at this exact moment, and the `List` re-asserts its own focus as part of
    /// settling that — which would otherwise register as "user clicked away" through the
    /// focus-loss `onChange` below and commit before the retry loop even finishes. Held `false`
    /// until that settling window passes, so those transient flickers are ignored; a real
    /// click-away still commits, just via the fallback check once the window closes.
    @State private var isSettled = false

    init(
        initialName: String,
        hiddenExtension: String?,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialName = initialName
        self.hiddenExtension = hiddenExtension
        self.onCommit = onCommit
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .task {
                // Rename-via-context-menu needs a longer window than create does: create's
                // `editingNodeID` assignment lands after an `await` round-trip through the
                // vault call, well clear of any focus AppKit reclaims while dismissing the
                // menu that triggered it; "Rename" sets it synchronously from the menu item's
                // own action, right as that dismissal is still settling.
                for _ in 0..<15 {
                    isFocused = true
                    try? await Task.sleep(for: .milliseconds(40))
                }
                isSettled = true
                if !isFocused { resolve(commit: true) }
            }
            .onSubmit { resolve(commit: true) }
            .onKeyPress(.return) {
                // Claimed here, not left to bubble to the List's own `.onKeyPress(.return)`
                // (which starts renaming the *selected* row) — without this, committing via
                // Return would immediately reopen the field it was just closing.
                resolve(commit: true)
                return .handled
            }
            .onKeyPress(.escape) {
                resolve(commit: false)
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                guard isSettled, !focused else { return }
                resolve(commit: true)
            }
    }

    private func resolve(commit: Bool) {
        guard !isResolved else { return }
        isResolved = true
        guard commit else {
            onCancel()
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ext = hiddenExtension, !trimmed.isEmpty, URL(fileURLWithPath: trimmed).pathExtension.isEmpty {
            // Nothing that looks like an extension was typed — restore the one we hid, rather
            // than leaving the user to type ".md" back in for every note they touch.
            onCommit("\(trimmed).\(ext)")
        } else {
            onCommit(name)
        }
    }
}
