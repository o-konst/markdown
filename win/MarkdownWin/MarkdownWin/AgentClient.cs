//
//  AgentClient.cs
//  MarkdownWin
//
//  Managed facade over the Rust `markdown_agent` library, which owns the whole conversation
//  with Claude — the HTTP call, the tool loop, and the safety caps. Mirrors AgentClient.swift
//  in shape: a handle, one blocking call pumped on a background thread, JSON in and out.
//
//  There is no callback from Rust into C#. `md_agent_poll_event` blocks and returns one event
//  at a time; this facade drains it on a dedicated background Thread (not a cooperative Task,
//  since the call can block for as long as the model takes to answer) and delivers each event
//  back to the caller on that same background thread — callers marshal to the UI thread
//  themselves, exactly like AgentClient.swift's `onEvent` closure does.
//

using System;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;

namespace MarkdownWin;

internal enum AgentEventKind
{
    Text,
    Thinking,
    ToolStarted,
    ToolFinished,
    Refused,
    Failed,
    Done,
}

internal sealed record AgentEvent(
    AgentEventKind Kind,
    string? Text = null,
    string? ToolName = null,
    bool? ToolOk = null,
    string? Detail = null,
    string? Commit = null,
    string? Category = null,
    string? Explanation = null,
    string? Message = null,
    string? StopReason = null);

internal sealed class AgentClient : IDisposable
{
    private IntPtr handle;
    private bool disposed;

    private AgentClient(IntPtr handle) => this.handle = handle;

    /// <summary>Fails (returns null) if the vault path cannot be opened; the API key itself is
    /// not validated until the first request.</summary>
    public static AgentClient? Open(string vaultRoot, string apiKey)
    {
        IntPtr handle = MarkdownCore.AgentOpen(vaultRoot, apiKey);
        return handle == IntPtr.Zero ? null : new AgentClient(handle);
    }

    /// <summary>
    /// Sends <paramref name="text"/> and streams the reply. <paramref name="onEvent"/> fires on
    /// a background thread for every event, ending with exactly one Done, Refused or Failed.
    /// Returns false without sending anything if a turn is already running.
    /// </summary>
    public bool Send(string text, Action<AgentEvent> onEvent)
    {
        ObjectDisposedException.ThrowIf(disposed, this);

        if (!MarkdownCore.AgentSendStart(handle, text))
        {
            return false;
        }

        IntPtr session = handle;
        var thread = new Thread(() =>
        {
            while (MarkdownCore.AgentPollEvent(session) is string json)
            {
                if (TryDecode(json, out AgentEvent evt))
                {
                    onEvent(evt);
                }
            }
        })
        {
            IsBackground = true,
            Name = "AgentClient.Poll",
        };
        thread.Start();
        return true;
    }

    private static bool TryDecode(string json, out AgentEvent evt)
    {
        evt = null!;
        try
        {
            if (JsonNode.Parse(json) is not JsonObject node)
            {
                return false;
            }

            if (node["type"]?.GetValue<string>() is not string type)
            {
                return false;
            }

            switch (type)
            {
                case "text":
                    if (node["text"]?.GetValue<string>() is not string textDelta)
                    {
                        return false;
                    }

                    evt = new AgentEvent(AgentEventKind.Text, Text: textDelta);
                    return true;

                case "thinking":
                    if (node["text"]?.GetValue<string>() is not string thinking)
                    {
                        return false;
                    }

                    evt = new AgentEvent(AgentEventKind.Thinking, Text: thinking);
                    return true;

                case "tool_started":
                    if (node["name"]?.GetValue<string>() is not string startedName)
                    {
                        return false;
                    }

                    evt = new AgentEvent(AgentEventKind.ToolStarted, ToolName: startedName);
                    return true;

                case "tool_finished":
                    if (node["name"]?.GetValue<string>() is not string finishedName ||
                        node["ok"]?.GetValue<bool>() is not bool ok ||
                        node["detail"]?.GetValue<string>() is not string detail)
                    {
                        return false;
                    }

                    evt = new AgentEvent(
                        AgentEventKind.ToolFinished,
                        ToolName: finishedName,
                        ToolOk: ok,
                        Detail: detail,
                        Commit: node["commit"]?.GetValue<string>());
                    return true;

                case "refused":
                    evt = new AgentEvent(
                        AgentEventKind.Refused,
                        Category: node["category"]?.GetValue<string>(),
                        Explanation: node["explanation"]?.GetValue<string>());
                    return true;

                case "failed":
                    if (node["message"]?.GetValue<string>() is not string message)
                    {
                        return false;
                    }

                    evt = new AgentEvent(AgentEventKind.Failed, Message: message);
                    return true;

                case "done":
                    if (node["stop_reason"]?.GetValue<string>() is not string stopReason)
                    {
                        return false;
                    }

                    evt = new AgentEvent(AgentEventKind.Done, StopReason: stopReason);
                    return true;

                default:
                    return false;
            }
        }
        catch (JsonException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            // A field was present but the wrong JSON kind (e.g. "ok" not a bool).
            return false;
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        // A turn in flight keeps running on its own Rust-owned thread even after this handle
        // closes; our polling loop above simply gets NULL (and exits on its own) once that
        // thread finishes and drops its sender, so there is nothing to join here.
        MarkdownCore.AgentClose(handle);
        handle = IntPtr.Zero;
    }
}
