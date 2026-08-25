//
//  ChatViewModel.cs
//  MarkdownWin
//
//  The chat transcript and the one AgentClient turn in flight at a time. Mirrors
//  ChatViewModel.swift.
//

using System;
using System.Collections.ObjectModel;
using System.Linq;
using Microsoft.UI.Dispatching;

namespace MarkdownWin;

internal sealed class ChatViewModel : ObservableBase, IDisposable
{
    public ObservableCollection<ChatMessage> Messages { get; } = new();

    private string draft = string.Empty;
    public string Draft
    {
        get => draft;
        set => Set(ref draft, value);
    }

    private bool isResponding;
    public bool IsResponding
    {
        get => isResponding;
        private set => Set(ref isResponding, value);
    }

    private string? errorMessage;
    public string? ErrorMessage
    {
        get => errorMessage;
        private set => Set(ref errorMessage, value);
    }

    private readonly DispatcherQueue dispatcherQueue;

    /// <summary>Recreated whenever the vault changes, so a stale session is never reused.</summary>
    private AgentClient? client;
    private string? clientVaultRoot;

    public ChatViewModel(DispatcherQueue dispatcherQueue) => this.dispatcherQueue = dispatcherQueue;

    public void Send(string vaultRoot)
    {
        string text = Draft.Trim();
        if (text.Length == 0 || IsResponding)
        {
            return;
        }

        if (ClientFor(vaultRoot) is not { } current)
        {
            return; // ErrorMessage already set; no messages appended, matches Swift.
        }

        Draft = string.Empty;
        ErrorMessage = null;
        var user = ChatMessage.User(text);
        var assistant = ChatMessage.Assistant();
        Messages.Add(user);
        Messages.Add(assistant);
        IsResponding = true;

        bool started = current.Send(text, evt => dispatcherQueue.TryEnqueue(() => Apply(evt, assistant)));
        if (!started)
        {
            // Can only happen if a previous turn's background thread has not finished
            // draining yet; IsResponding normally prevents this from being reachable.
            IsResponding = false;
            Messages.Remove(assistant);
            Messages.Remove(user);
            Draft = text;
            ErrorMessage = "The assistant is still finishing the last message.";
        }
    }

    /// <summary>Opens (or reuses) the session for <paramref name="vaultRoot"/>. Fails, with a
    /// message set, when there is no API key yet.</summary>
    private AgentClient? ClientFor(string vaultRoot)
    {
        if (client is { } existing && clientVaultRoot == vaultRoot)
        {
            return existing;
        }

        (string? key, CredentialStoreStatus status) = CredentialStore.TryGetApiKey();
        if (status == CredentialStoreStatus.Unavailable)
        {
            ErrorMessage = "The API key could not be read from Windows Credential Manager.";
            return null;
        }

        if (string.IsNullOrEmpty(key))
        {
            ErrorMessage = "Add an Anthropic API key in Settings to use the assistant.";
            return null;
        }

        client?.Dispose();

        AgentClient? opened = AgentClient.Open(vaultRoot, key);
        if (opened is null)
        {
            ErrorMessage = "Could not open the assistant for this folder.";
            return null;
        }

        client = opened;
        clientVaultRoot = vaultRoot;
        return opened;
    }

    /// <summary>Applies one decoded event to <see cref="Messages"/>. Called on the UI thread.</summary>
    private void Apply(AgentEvent evt, ChatMessage assistant)
    {
        switch (evt.Kind)
        {
            case AgentEventKind.Text:
                assistant.AppendAssistantDelta(evt.Text!);
                break;

            case AgentEventKind.Thinking:
                // Summarised reasoning; not surfaced in this first pass.
                break;

            case AgentEventKind.ToolStarted:
                Messages.Add(ChatMessage.ToolStarted(evt.ToolName!));
                break;

            case AgentEventKind.ToolFinished:
                // Matched from the end: tools can run more than once in a turn, so this finds
                // the most recent still-running row for that name rather than the first.
                ChatMessage? running = Messages
                    .Reverse()
                    .FirstOrDefault(m => m.Kind == ChatMessageKind.Tool && m.ToolName == evt.ToolName && m.ToolOk is null);
                running?.ApplyToolFinished(evt.ToolOk!.Value, evt.Detail!, evt.Commit);
                break;

            case AgentEventKind.Refused:
                IsResponding = false;
                string reason = string.Join(": ", new[] { evt.Category, evt.Explanation }.Where(s => !string.IsNullOrEmpty(s)));
                Messages.Add(ChatMessage.Notice(reason.Length == 0 ? "The assistant declined to continue." : reason));
                break;

            case AgentEventKind.Failed:
                IsResponding = false;
                Messages.Add(ChatMessage.Notice(evt.Message!));
                break;

            case AgentEventKind.Done:
                IsResponding = false;
                break;
        }
    }

    public void Dispose() => client?.Dispose();
}
