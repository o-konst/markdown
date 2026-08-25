//
//  EditorToolbarState.swift
//  Markdown
//
//  Snapshot of the WYSIWYG editor's current selection/mode, pushed from the web view via
//  the `"editorStateChanged"` bridge message — see `vue-project/src/bridge/nativeBridge.ts`'s
//  `EditorToolbarState` interface, which this mirrors field-for-field.
//

import Foundation

struct EditorToolbarState: Equatable {
    enum Mode: String {
        case reading
        case edit
    }

    enum Mark: String {
        case bold
        case italic
        case strike
        case code
    }

    enum Block: String {
        case blockquote
        case bulletList
        case orderedList
        case taskList
        case codeBlock
    }

    var mode: Mode
    var isEditable: Bool
    var activeMarks: Set<Mark>
    var headingLevel: Int?
    var activeBlock: Block?
    var linkActive: Bool
    var canUndo: Bool
    var canRedo: Bool

    /// Before the first `"editorStateChanged"` message arrives (or once the web view is
    /// showing Reading view, where no editor state is relevant), a toolbar reading this
    /// should show everything as unavailable rather than a stale or arbitrary guess.
    static let initial = EditorToolbarState(
        mode: .edit,
        isEditable: false,
        activeMarks: [],
        headingLevel: nil,
        activeBlock: nil,
        linkActive: false,
        canUndo: false,
        canRedo: false
    )

    /// Decodes the `state` payload of an `"editorStateChanged"` bridge message. Unknown
    /// mark/block names are dropped rather than failing the whole decode, matching the web
    /// UI's own `normalizePreferences` tolerance philosophy ("a host on a different
    /// version cannot put the UI into a nonsense state") applied in the other direction.
    init?(body: [String: Any]) {
        guard let modeRaw = body["mode"] as? String, let mode = Mode(rawValue: modeRaw) else {
            return nil
        }
        self.mode = mode
        self.isEditable = body["isEditable"] as? Bool ?? false

        let markStrings = body["activeMarks"] as? [String] ?? []
        self.activeMarks = Set(markStrings.compactMap(Mark.init(rawValue:)))

        self.headingLevel = body["headingLevel"] as? Int
        self.activeBlock = (body["activeBlock"] as? String).flatMap(Block.init(rawValue:))
        self.linkActive = body["linkActive"] as? Bool ?? false
        self.canUndo = body["canUndo"] as? Bool ?? false
        self.canRedo = body["canRedo"] as? Bool ?? false
    }

    private init(
        mode: Mode,
        isEditable: Bool,
        activeMarks: Set<Mark>,
        headingLevel: Int?,
        activeBlock: Block?,
        linkActive: Bool,
        canUndo: Bool,
        canRedo: Bool
    ) {
        self.mode = mode
        self.isEditable = isEditable
        self.activeMarks = activeMarks
        self.headingLevel = headingLevel
        self.activeBlock = activeBlock
        self.linkActive = linkActive
        self.canUndo = canUndo
        self.canRedo = canRedo
    }
}
