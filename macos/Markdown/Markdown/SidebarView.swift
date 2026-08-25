//
//  SidebarView.swift
//  Markdown
//
//  The folder tree, the search results that replace it while searching, and the account
//  row pinned to the bottom.
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Bindable var workspace: Workspace
    let account: Account
    let openFolder: () -> Void
    let openFile: () -> Void
    let openSettings: () -> Void
    let openLogin: () -> Void
    let openChat: () -> Void

    @State private var isOpenDropTargeted = false

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
                        ForEach(root.children ?? []) { child in
                            AnyView(FileTreeRow(node: child))
                        }
                    } header: {
                        Text(root.name)
                    }
                }
                .listStyle(.sidebar)
                .contextMenu {
                    Button("Refresh") { root.reload() }
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
                Button("Assistant", systemImage: "sparkles") { openChat() }
                    .help("Ask the assistant about this folder")
            }
        }
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

    var body: some View {
        if node.isDirectory {
            directory
        } else {
            Label(node.name, systemImage: "doc.text")
                .tag(node.url)
        }
    }

    private var directory: some View {
        DisclosureGroup(isExpanded: $node.isExpanded) {
            ForEach(node.children ?? []) { child in
                AnyView(FileTreeRow(node: child))
            }
        } label: {
            Label(node.name, systemImage: "folder")
        }
        .onChange(of: node.isExpanded, initial: true) { _, isExpanded in
            if isExpanded { node.loadChildren() }
        }
        .contextMenu {
            Button("Refresh") { node.reload() }
        }
    }
}
