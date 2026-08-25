//
//  EditorFormattingToolbar.swift
//  Markdown
//
//  The native formatting toolbar for the WYSIWYG editor. Every button dispatches a
//  command string (see `vue-project/src/editor/formatCommands.ts`) over
//  `WebPreviewCoordinator.runEditorCommand(_:payload:)`; active/pressed state comes back
//  the other way as an `EditorToolbarState` (`"editorStateChanged"` bridge messages).
//
//  Conforms to `ToolbarContent` (not `View`) so each button becomes its own real toolbar
//  item when spliced into `ContentView`'s `.toolbar { }` — a plain `View` whose `body`
//  composes several sibling views would render as one opaque, squished toolbar item
//  instead of separately spaced ones, since `some View` erases the underlying multi-view
//  structure that `ToolbarItemGroup`/`.toolbar` needs to see to lay them out individually.
//
//  Table row/column controls are deliberately NOT here — they stay as the existing
//  in-content `TableControls.vue`, since they're contextual to being inside a table, not a
//  global toolbar concern. Undo/redo buttons are also deliberately absent: WKWebView's
//  contenteditable undo is DOM-native, so Cmd+Z/Cmd+Shift+Z are expected to already work
//  while the web view has focus with no custom wiring — this hasn't been interactively
//  verified (no way to drive the GUI from this environment), so no undo/redo commands or
//  buttons were added speculatively. `EditorToolbarState.canUndo`/`canRedo` are still
//  reported and decoded, ready to back real buttons later if verification shows they're
//  actually needed.
//

import SwiftUI

struct EditorFormattingToolbar: ToolbarContent {
    var state: EditorToolbarState
    /// Additionally requires the Source-view toggle to be off — a plain-text overlay
    /// showing while the WYSIWYG editor is (invisibly) still there underneath is not a
    /// state where formatting commands make sense to offer.
    var isSourceViewShowing: Bool
    var run: (_ command: String, _ payload: [String: Any]?) -> Void

    @State private var isShowingLinkPopover = false
    @State private var linkURLText = ""
    @State private var isShowingImagePopover = false
    @State private var imageURLText = ""
    @State private var isShowingFootnotePopover = false
    @State private var footnoteLabelText = ""

    private var isAvailable: Bool {
        state.isEditable && !isSourceViewShowing
    }

    // Split into several grouped sections rather than one flat list of ~16 `ToolbarItem`s:
    // `@ToolbarContentBuilder`'s `buildBlock` (like `@ViewBuilder`'s) only has overloads up
    // to 10 children — a single `body` listing every button hit that ceiling and failed to
    // compile ("extra arguments" pointing at the items past #10). Each section below stays
    // safely under that limit; `body` itself only composes 4 of them together.
    var body: some ToolbarContent {
        modeSection
        markSection
        blockSection
        insertSection
    }

    @ToolbarContentBuilder
    private var modeSection: some ToolbarContent {
        ToolbarItem {
            Toggle(isOn: modeBinding) {
                Label(
                    state.mode == .edit ? "Reading View" : "Edit",
                    systemImage: state.mode == .edit ? "eye" : "pencil"
                )
            }
            .toggleStyle(.button)
            .help(state.mode == .edit ? "Switch to Reading view" : "Switch to Edit mode")
        }
        ToolbarItem { Divider() }
    }

    @ToolbarContentBuilder
    private var markSection: some ToolbarContent {
        ToolbarItem { markButton(.bold, symbol: "bold", help: "Bold") }
        ToolbarItem { markButton(.italic, symbol: "italic", help: "Italic") }
        ToolbarItem { markButton(.strike, symbol: "strikethrough", help: "Strikethrough") }
        ToolbarItem {
            markButton(.code, symbol: "chevron.left.forwardslash.chevron.right", help: "Inline Code")
        }
        ToolbarItem {
            Menu {
                Button("Paragraph") { run("setHeading", ["level": NSNull()]) }
                Divider()
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { run("setHeading", ["level": level]) }
                }
            } label: {
                Label(headingMenuTitle, systemImage: "textformat.size")
            }
            .disabled(!isAvailable)
            .help("Heading level")
        }
    }

    @ToolbarContentBuilder
    private var blockSection: some ToolbarContent {
        ToolbarItem { blockButton(.blockquote, symbol: "text.quote", help: "Blockquote") }
        ToolbarItem { blockButton(.bulletList, symbol: "list.bullet", help: "Bullet List") }
        ToolbarItem { blockButton(.orderedList, symbol: "list.number", help: "Numbered List") }
        ToolbarItem { blockButton(.taskList, symbol: "checklist", help: "Task List") }
        ToolbarItem { blockButton(.codeBlock, symbol: "terminal", help: "Code Block") }
    }

    @ToolbarContentBuilder
    private var insertSection: some ToolbarContent {
        ToolbarItem {
            Button {
                run("setHorizontalRule", nil)
            } label: {
                Label("Horizontal Rule", systemImage: "minus")
            }
            .disabled(!isAvailable)
            .help("Insert a horizontal rule")
        }
        ToolbarItem { linkButton }
        ToolbarItem { imageButton }
        ToolbarItem { footnoteButton }
    }

    private var modeBinding: Binding<Bool> {
        Binding(
            get: { state.mode == .edit },
            set: { isEdit in run("setMode", ["mode": isEdit ? "edit" : "reading"]) }
        )
    }

    private var headingMenuTitle: String {
        state.headingLevel.map { "H\($0)" } ?? "Text"
    }

    private func markButton(_ mark: EditorToolbarState.Mark, symbol: String, help: String) -> some View {
        Button {
            run(markCommand(mark), nil)
        } label: {
            Label(help, systemImage: symbol)
        }
        .tint(state.activeMarks.contains(mark) ? Color.accentColor : nil)
        .disabled(!isAvailable)
        .help(help)
    }

    private func markCommand(_ mark: EditorToolbarState.Mark) -> String {
        switch mark {
        case .bold: return "toggleBold"
        case .italic: return "toggleItalic"
        case .strike: return "toggleStrike"
        case .code: return "toggleCode"
        }
    }

    private func blockButton(_ block: EditorToolbarState.Block, symbol: String, help: String) -> some View {
        Button {
            run(blockCommand(block), nil)
        } label: {
            Label(help, systemImage: symbol)
        }
        .tint(state.activeBlock == block ? Color.accentColor : nil)
        .disabled(!isAvailable)
        .help(help)
    }

    private func blockCommand(_ block: EditorToolbarState.Block) -> String {
        switch block {
        case .blockquote: return "toggleBlockquote"
        case .bulletList: return "toggleBulletList"
        case .orderedList: return "toggleOrderedList"
        case .taskList: return "toggleTaskList"
        case .codeBlock: return "toggleCodeBlock"
        }
    }

    private var linkButton: some View {
        Button {
            linkURLText = ""
            isShowingLinkPopover = true
        } label: {
            Label("Link", systemImage: "link")
        }
        .tint(state.linkActive ? Color.accentColor : nil)
        .disabled(!isAvailable)
        .help("Link")
        .popover(isPresented: $isShowingLinkPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Link URL").font(.headline)
                TextField("https://example.com", text: $linkURLText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240)
                    .onSubmit(applyLink)
                HStack {
                    if state.linkActive {
                        Button("Remove", role: .destructive) {
                            run("toggleLink", nil)
                            isShowingLinkPopover = false
                        }
                    }
                    Spacer()
                    Button("Apply", action: applyLink)
                        .keyboardShortcut(.defaultAction)
                        .disabled(linkURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    private func applyLink() {
        let trimmed = linkURLText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        run("toggleLink", ["href": trimmed])
        isShowingLinkPopover = false
    }

    private var imageButton: some View {
        Button {
            imageURLText = ""
            isShowingImagePopover = true
        } label: {
            Label("Image", systemImage: "photo")
        }
        .disabled(!isAvailable)
        .help("Insert an image from a URL")
        .popover(isPresented: $isShowingImagePopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Image URL").font(.headline)
                TextField("https://example.com/image.png", text: $imageURLText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240)
                    .onSubmit(applyImage)
                HStack {
                    Spacer()
                    Button("Insert", action: applyImage)
                        .keyboardShortcut(.defaultAction)
                        .disabled(imageURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    private func applyImage() {
        let trimmed = imageURLText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        run("setImage", ["src": trimmed])
        isShowingImagePopover = false
    }

    private var footnoteButton: some View {
        Button {
            footnoteLabelText = ""
            isShowingFootnotePopover = true
        } label: {
            Label("Footnote", systemImage: "textformat.superscript")
        }
        .disabled(!isAvailable)
        .help("Insert a footnote")
        .popover(isPresented: $isShowingFootnotePopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Footnote Label").font(.headline)
                TextField("note", text: $footnoteLabelText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    .onSubmit(applyFootnote)
                HStack {
                    Spacer()
                    Button("Insert", action: applyFootnote)
                        .keyboardShortcut(.defaultAction)
                        .disabled(footnoteLabelText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    private func applyFootnote() {
        let trimmed = footnoteLabelText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        run("insertFootnote", ["label": trimmed])
        isShowingFootnotePopover = false
    }
}
