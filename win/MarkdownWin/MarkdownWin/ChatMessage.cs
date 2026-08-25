//
//  ChatMessage.cs
//  MarkdownWin
//
//  One row of the assistant transcript. Mirrors ChatViewModel.swift's ChatMessage, but as a
//  mutable, INotifyPropertyChanged class rather than an immutable struct: WinUI's ListView
//  only redraws a row on its own PropertyChanged, not on collection-level Replace, so
//  streaming text and flipping a tool call from running to finished mutate in place.
//
//  Unlike Swift's reassignable enum case, Kind is fixed at construction here — a message
//  never becomes a different kind of row after it's created.
//

namespace MarkdownWin;

internal enum ChatMessageKind
{
    User,
    Assistant,
    Tool,
    Notice,
}

internal sealed class ChatMessage : ObservableBase
{
    public ChatMessageKind Kind { get; }

    private string text = string.Empty;

    /// <summary>User/assistant bubble text, or the notice text. Assistant text is appended to
    /// incrementally as `.text` deltas arrive.</summary>
    public string Text
    {
        get => text;
        private set
        {
            if (Set(ref text, value))
            {
                Notify(nameof(DisplayText));
            }
        }
    }

    /// <summary>"…" placeholder while an assistant bubble is still empty (streaming hasn't
    /// produced text yet).</summary>
    public string DisplayText => Kind == ChatMessageKind.Assistant && text.Length == 0 ? "…" : text;

    public string? ToolName { get; private init; }

    private bool? toolOk;

    /// <summary>Null while running (spinner), true/false once finished.</summary>
    public bool? ToolOk
    {
        get => toolOk;
        private set
        {
            if (Set(ref toolOk, value))
            {
                Notify(nameof(IsToolRunning));
                Notify(nameof(IsToolSucceeded));
                Notify(nameof(IsToolFailed));
            }
        }
    }

    /// <summary>Tri-state helpers for the status glyph — x:Bind auto-converts bool to Visibility.</summary>
    public bool IsToolRunning => ToolOk is null;
    public bool IsToolSucceeded => ToolOk == true;
    public bool IsToolFailed => ToolOk == false;

    private string toolDetail = "Running…";
    public string ToolDetail
    {
        get => toolDetail;
        private set => Set(ref toolDetail, value);
    }

    public string? ToolCommit { get; private set; }

    private ChatMessage(ChatMessageKind kind) => Kind = kind;

    public static ChatMessage User(string text) => new(ChatMessageKind.User) { text = text };

    public static ChatMessage Assistant() => new(ChatMessageKind.Assistant);

    public static ChatMessage Notice(string text) => new(ChatMessageKind.Notice) { text = text };

    public static ChatMessage ToolStarted(string name) => new(ChatMessageKind.Tool) { ToolName = name };

    public void AppendAssistantDelta(string delta)
    {
        // Guards a stale reference, mirroring the Swift `if case .assistant` check — in
        // practice Kind never changes after construction here, so this can't actually fire.
        if (Kind != ChatMessageKind.Assistant)
        {
            return;
        }

        Text += delta;
    }

    public void ApplyToolFinished(bool ok, string detail, string? commit)
    {
        ToolOk = ok;
        ToolDetail = detail;
        ToolCommit = commit;
        Notify(nameof(ToolCommit));
    }
}
