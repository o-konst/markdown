//
//  ContentView.swift
//  Markdown
//
//  Created by Konstantin Ogai on 24/08/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isChoosingFolder = false
    @State private var isChoosingFile = false
    @State private var isEditing = false
    @State private var isDropTargeted = false
    @State private var isShowingPDFThumbnails = false

    /// Whether the document outline panel is open — a toolbar-driven open/close panel
    /// like `isShowingPDFThumbnails`, not a persisted setting (there used to be a
    /// "Show contents tree" toggle in Settings; removed in favor of this).
    @State private var isShowingOutline = false

    @State private var isShowingSettings = false
    @State private var isShowingLogin = false
    @State private var isShowingChat = false
    @State private var account = Account()

    /// Settings own the rendering options; the web UI owns the divider's width.
    @AppStorage(PreferenceKey.contentWidth) private var contentWidth = ContentWidth.full
    @AppStorage(PreferenceKey.fontSize) private var fontSize = FontSize.standard
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system

    /// Reported by the web UI: false for documents with nothing to navigate.
    @State private var isOutlineAvailable = false

    /// Reported by the web UI on every editor transaction — drives `EditorFormattingToolbar`.
    @State private var toolbarState = EditorToolbarState.initial

    /// Set once the web view's coordinator exists (see `MarkdownWebView.registerRunEditorCommand`).
    /// A local `@State` closure rather than something routed through `Workspace`, unlike
    /// `flushEditorPendingEdit` — this is a purely UI-local concern (the toolbar), not
    /// something `Workspace` itself ever needs to call.
    @State private var runEditorCommand: (String, [String: Any]?) async -> Bool = { _, _ in false }

    private var preferences: WebPreferences {
        WebPreferences(
            outlineVisible: isShowingOutline,
            contentWidth: contentWidth,
            fontSize: fontSize
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                workspace: workspace,
                account: account,
                openFolder: { isChoosingFolder = true },
                openFile: { isChoosingFile = true },
                openSettings: { isShowingSettings = true },
                openLogin: { isShowingLogin = true },
                openChat: { isShowingChat = true }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            detail
                .toolbar {
                    // Formatting commands and the WYSIWYG/source toggle only make sense
                    // for the Markdown editor — image/PDF/plain-text views have neither,
                    // and neither does the welcome screen shown when nothing is open.
                    if !workspace.isEmpty && workspace.selectedFileKind == .markdown {
                        EditorFormattingToolbar(
                            state: toolbarState,
                            isSourceViewShowing: isEditing,
                            run: { command, payload in
                                Task { @MainActor in _ = await runEditorCommand(command, payload) }
                            }
                        )

                        ToolbarItem {
                            // The WYSIWYG editor (`preview`, below) is the primary way to edit
                            // now — this toggle shows the plain-text source as a fallback, not
                            // the main editing surface. Kept, not removed: a real two-way
                            // binding to `workspace.text` like everything else, so editing
                            // here is never an echo, just another writer.
                            Toggle(isOn: $isEditing) {
                                Label("Source", systemImage: "curlybraces")
                            }
                            .toggleStyle(.button)
                            .keyboardShortcut("e", modifiers: .command)
                            .help(isEditing ? "Hide the raw Markdown source" : "Show the raw Markdown source")
                        }

                        ToolbarItem {
                            Toggle(isOn: $isShowingOutline) {
                                Label("Contents", systemImage: "list.bullet.indent")
                            }
                            .toggleStyle(.button)
                            .disabled(!isOutlineAvailable)
                            .help(isOutlineAvailable
                                  ? (isShowingOutline ? "Hide Contents" : "Show Contents")
                                  : "This document has no sections to navigate")
                        }
                    }

                    if workspace.selectedFileKind == .pdf {
                        ToolbarItem {
                            Toggle(isOn: $isShowingPDFThumbnails) {
                                Label("Page Thumbnails", systemImage: "sidebar.right")
                            }
                            .toggleStyle(.button)
                            .help(isShowingPDFThumbnails ? "Hide Page Thumbnails" : "Show Page Thumbnails")
                        }
                    }
                }
        }
        .navigationTitle(workspace.documentTitle)
        .searchable(
            text: $workspace.searchQuery,
            placement: .toolbar,
            prompt: "Search names and contents"
        )
        // Also drives the web view: it reads the window's appearance as `prefers-color-scheme`.
        .preferredColorScheme(appearance.colorScheme)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in await workspace.open(folder: url) }
            case .failure(let error):
                workspace.reportOpenFailure(error)
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: MarkdownFile.contentTypes) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in await workspace.open(file: url) }
            case .failure(let error):
                workspace.reportOpenFailure(error)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await workspace.open(dropped: url) }
            }
            return true
        }
        // Reached when a folder or file is dropped on the Dock icon or a Finder-toolbar
        // shortcut to the app, or opened via "Open With" — declared in Info.plist's
        // `CFBundleDocumentTypes`. Same routing as an in-app drop, so behavior matches.
        .onOpenURL { url in
            Task { @MainActor in await workspace.open(dropped: url) }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $isShowingLogin) {
            LoginView(account: account)
        }
        .sheet(isPresented: $isShowingChat) {
            ChatView(vaultRoot: workspace.root?.url)
        }
        .focusedSceneValue(\.folderPicker, $isChoosingFolder)
        .focusedSceneValue(\.filePicker, $isChoosingFile)
        .focusedSceneValue(\.workspace, workspace)
    }

    /// Routes to a view per selected file kind. Markdown keeps the WYSIWYG editor (with
    /// the raw-source overlay layered on top, on demand, so toggling it does not tear
    /// down the web view and reload the whole web UI); everything else gets its own
    /// dedicated, non-Markdown view.
    private var detail: some View {
        Group {
            if workspace.isEmpty {
                WelcomeView(
                    workspace: workspace,
                    openFolder: { isChoosingFolder = true },
                    openFile: { isChoosingFile = true }
                )
            } else {
                switch workspace.selectedFileKind {
                case .markdown:
                    ZStack {
                        preview
                        if isEditing {
                            editor
                        }
                    }
                case .plainText:
                    editor
                case .image:
                    if let url = workspace.selectedFile {
                        ImageViewer(url: url)
                    }
                case .pdf:
                    if let url = workspace.selectedFile {
                        PDFViewerView(url: url, isShowingThumbnails: isShowingPDFThumbnails)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private var editor: some View {
        TextEditor(text: $workspace.text)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 16)
            .background(.background)
    }

    private var preview: some View {
        MarkdownWebView(
            text: workspace.text,
            preferences: preferences,
            onOutlineAvailabilityChange: { isOutlineAvailable = $0 },
            onDocumentEdit: { workspace.text = $0 },
            registerFlushPendingEdit: { workspace.flushEditorPendingEdit = $0 },
            onEditorStateChange: { toolbarState = $0 },
            registerRunEditorCommand: { runEditorCommand = $0 },
            importAsset: { try workspace.importAsset(filename: $0, data: $1) },
            readAsset: { workspace.readAsset($0) },
            vaultRootURL: workspace.root?.url
        )
    }

}

// MARK: - Menu plumbing

/// Lets the File menu drive the frontmost window's pickers and opened folder or file.
extension FocusedValues {
    @Entry var folderPicker: Binding<Bool>?
    @Entry var filePicker: Binding<Bool>?
    @Entry var workspace: Workspace?

    /// Published by `SidebarView`, since the name-prompt state (and the target-directory rule
    /// in decision 6) lives there — the File menu just triggers it for the frontmost window.
    @Entry var newNoteAction: (() -> Void)?
    @Entry var newFolderAction: (() -> Void)?
}

#Preview {
    ContentView()
}
