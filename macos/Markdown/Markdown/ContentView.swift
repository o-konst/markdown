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

    @State private var isShowingSettings = false
    @State private var isShowingLogin = false
    @State private var isShowingChat = false
    @State private var account = Account()

    /// Settings own the rendering options; the web UI owns the divider's width.
    @AppStorage(PreferenceKey.outlineVisible) private var outlineVisible = true
    @AppStorage(PreferenceKey.contentWidth) private var contentWidth = ContentWidth.full
    @AppStorage(PreferenceKey.fontSize) private var fontSize = FontSize.standard
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system

    /// Reported by the web UI: false for documents with nothing to navigate.
    @State private var isOutlineAvailable = false

    private var preferences: WebPreferences {
        WebPreferences(
            outlineVisible: outlineVisible,
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
                workspace.open(folder: url)
            case .failure(let error):
                workspace.reportOpenFailure(error)
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: MarkdownFile.contentTypes) { result in
            switch result {
            case .success(let url):
                workspace.open(file: url)
            case .failure(let error):
                workspace.reportOpenFailure(error)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in workspace.open(dropped: url) }
            }
            return true
        }
        // Reached when a folder or file is dropped on the Dock icon or a Finder-toolbar
        // shortcut to the app, or opened via "Open With" — declared in Info.plist's
        // `CFBundleDocumentTypes`. Same routing as an in-app drop, so behavior matches.
        .onOpenURL { url in
            workspace.open(dropped: url)
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
            SettingsView(isOutlineAvailable: isOutlineAvailable)
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

    /// The preview fills the detail column; the editor covers it on demand.
    ///
    /// The editor is layered over the preview rather than swapped with it, so toggling
    /// edit mode does not tear down the web view and reload the whole web UI.
    private var detail: some View {
        ZStack {
            preview
            if isEditing {
                editor
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private var editor: some View {
        TextEditor(text: $workspace.text)
            .font(.system(.body, design: .monospaced))
            .background(.background)
    }

    private var preview: some View {
        MarkdownWebView(
            text: workspace.text,
            preferences: preferences,
            onOutlineAvailabilityChange: { isOutlineAvailable = $0 },
            onDocumentEdit: { workspace.text = $0 }
        )
    }

}

// MARK: - Menu plumbing

/// Lets the File menu drive the frontmost window's pickers and opened folder or file.
extension FocusedValues {
    @Entry var folderPicker: Binding<Bool>?
    @Entry var filePicker: Binding<Bool>?
    @Entry var workspace: Workspace?
}

#Preview {
    ContentView()
}
