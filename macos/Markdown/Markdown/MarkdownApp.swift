//
//  MarkdownApp.swift
//  Markdown
//
//  Created by Konstantin Ogai on 24/08/2026.
//

import SwiftUI

@main
struct MarkdownApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            FolderCommands()
            #if os(macOS)
            SidebarCommands()
            #endif
        }
    }
}

#if os(macOS)
/// This is a single-window app with nothing useful to do once that window is gone — quit
/// with it, rather than leaving a windowless app running in the Dock, which is the default
/// SwiftUI/AppKit behavior for `WindowGroup`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

/// File-menu entries for the opened folder or file. They act on the frontmost window.
struct FolderCommands: Commands {
    @FocusedValue(\.folderPicker) private var folderPicker
    @FocusedValue(\.filePicker) private var filePicker
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open File…") { filePicker?.wrappedValue = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(filePicker == nil)

            Button("Open Folder…") { folderPicker?.wrappedValue = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(folderPicker == nil)

            Button(workspace?.root != nil ? "Close Folder" : "Close File") {
                Task { @MainActor in await workspace?.close() }
            }
            .disabled(workspace?.root == nil && workspace?.selectedFile == nil)
        }
    }
}
