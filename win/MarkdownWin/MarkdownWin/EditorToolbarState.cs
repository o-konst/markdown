//
//  EditorToolbarState.cs
//  MarkdownWin
//
//  Snapshot of the WYSIWYG editor's current selection/mode, pushed from the web view via the
//  `"editorStateChanged"` bridge message — see `vue-project/src/bridge/nativeBridge.ts`'s
//  `EditorToolbarState` interface, which this mirrors field-for-field. Mirrors
//  EditorToolbarState.swift.
//

using System.Collections.Generic;
using System.Text.Json.Nodes;

namespace MarkdownWin;

internal enum EditorMode
{
    Reading,
    Edit,
}

internal enum EditorMark
{
    Bold,
    Italic,
    Strike,
    Code,
}

internal enum EditorBlock
{
    Blockquote,
    BulletList,
    OrderedList,
    TaskList,
    CodeBlock,
}

internal readonly record struct EditorToolbarState(
    EditorMode Mode,
    bool IsEditable,
    IReadOnlySet<EditorMark> ActiveMarks,
    int? HeadingLevel,
    EditorBlock? ActiveBlock,
    bool LinkActive,
    bool CanUndo,
    bool CanRedo)
{
    /// <summary>Before the first `"editorStateChanged"` message arrives (or once the web view
    /// is showing Reading view, where no editor state is relevant), a toolbar reading this
    /// should show everything as unavailable rather than a stale or arbitrary guess.</summary>
    public static readonly EditorToolbarState Initial = new(
        EditorMode.Edit,
        IsEditable: false,
        ActiveMarks: new HashSet<EditorMark>(),
        HeadingLevel: null,
        ActiveBlock: null,
        LinkActive: false,
        CanUndo: false,
        CanRedo: false);

    /// <summary>Decodes the `state` payload of an `"editorStateChanged"` bridge message.
    /// Unknown mark/block names are dropped rather than failing the whole decode, matching the
    /// web UI's own `normalizePreferences` tolerance philosophy applied in the other
    /// direction.</summary>
    public static EditorToolbarState? TryParse(JsonObject body)
    {
        if (body["mode"]?.GetValue<string>() is not string modeRaw || ParseMode(modeRaw) is not { } mode)
        {
            return null;
        }

        bool isEditable = body["isEditable"]?.GetValue<bool>() ?? false;

        var activeMarks = new HashSet<EditorMark>();
        if (body["activeMarks"] is JsonArray markArray)
        {
            foreach (JsonNode? item in markArray)
            {
                if (item?.GetValue<string>() is string raw && ParseMark(raw) is { } mark)
                {
                    activeMarks.Add(mark);
                }
            }
        }

        int? headingLevel = body["headingLevel"]?.GetValue<int>();
        EditorBlock? activeBlock = body["activeBlock"]?.GetValue<string>() is string blockRaw
            ? ParseBlock(blockRaw)
            : null;
        bool linkActive = body["linkActive"]?.GetValue<bool>() ?? false;
        bool canUndo = body["canUndo"]?.GetValue<bool>() ?? false;
        bool canRedo = body["canRedo"]?.GetValue<bool>() ?? false;

        return new EditorToolbarState(mode, isEditable, activeMarks, headingLevel, activeBlock, linkActive, canUndo, canRedo);
    }

    private static EditorMode? ParseMode(string raw) => raw switch
    {
        "reading" => EditorMode.Reading,
        "edit" => EditorMode.Edit,
        _ => null,
    };

    private static EditorMark? ParseMark(string raw) => raw switch
    {
        "bold" => EditorMark.Bold,
        "italic" => EditorMark.Italic,
        "strike" => EditorMark.Strike,
        "code" => EditorMark.Code,
        _ => null,
    };

    private static EditorBlock? ParseBlock(string raw) => raw switch
    {
        "blockquote" => EditorBlock.Blockquote,
        "bulletList" => EditorBlock.BulletList,
        "orderedList" => EditorBlock.OrderedList,
        "taskList" => EditorBlock.TaskList,
        "codeBlock" => EditorBlock.CodeBlock,
        _ => null,
    };
}
