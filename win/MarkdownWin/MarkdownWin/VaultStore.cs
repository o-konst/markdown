//
//  VaultStore.cs
//  MarkdownWin
//
//  Managed facade over the Rust `markdown_vault` library, which owns every read and write of
//  the notes folder along with its history. Mirrors VaultStore.swift on macOS.
//
//  Deliberately thin: one JSON call reaches every tool, so adding a tool is a change in
//  Rust alone. Path safety lives there too — nothing here validates a path, because
//  confine.rs already refuses anything outside the vault.
//

using System;
using System.IO;
using System.Text.Json.Nodes;

namespace MarkdownWin;

internal enum VaultErrorKind
{
    /// The vault could not be opened at all.
    Unavailable,
    /// The Rust side rejected the operation; the message is written for a person to read.
    Rejected,
    /// The reply was not the shape the ABI promises.
    MalformedReply,
}

internal sealed class VaultException : Exception
{
    public VaultErrorKind Kind { get; }

    public VaultException(VaultErrorKind kind, string message) : base(message) => Kind = kind;
}

/// <summary>An open notes vault.</summary>
internal sealed class VaultStore : IDisposable
{
    private IntPtr handle;
    private bool disposed;

    /// <summary>Opens <paramref name="root"/>, initialising history and recording a baseline commit on first use.</summary>
    public VaultStore(string root)
    {
        handle = MarkdownCore.VaultOpen(root);
        if (handle == IntPtr.Zero)
        {
            throw new VaultException(VaultErrorKind.Unavailable, $"Could not open the vault at {root}.");
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        MarkdownCore.VaultClose(handle);
        handle = IntPtr.Zero;
    }

    // MARK: - The one call

    /// <summary>Runs a vault tool and returns its `result` object.</summary>
    public JsonObject Call(string name, JsonObject? input = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);

        string inputJson = (input ?? new JsonObject()).ToJsonString();
        string? reply = MarkdownCore.VaultCall(handle, name, inputJson);
        if (reply is null)
        {
            throw new VaultException(VaultErrorKind.MalformedReply, "The vault returned an unexpected reply.");
        }

        JsonObject? envelope;
        try
        {
            envelope = JsonNode.Parse(reply) as JsonObject;
        }
        catch (System.Text.Json.JsonException)
        {
            envelope = null;
        }

        if (envelope is null)
        {
            throw new VaultException(VaultErrorKind.MalformedReply, "The vault returned an unexpected reply.");
        }

        bool ok = envelope["ok"]?.GetValue<bool>() ?? false;
        if (!ok)
        {
            string message = envelope["error"]?.GetValue<string>() ?? "The vault refused that.";
            throw new VaultException(VaultErrorKind.Rejected, message);
        }

        return envelope["result"] as JsonObject ?? new JsonObject();
    }

    // MARK: - Typed conveniences

    public string Read(string path)
    {
        JsonObject result = Call("read_note", new JsonObject { ["path"] = path });
        return result["content"]?.GetValue<string>()
            ?? throw new VaultException(VaultErrorKind.MalformedReply, "The vault returned an unexpected reply.");
    }

    /// <summary>Returns the commit id, or null when the contents were already what was asked for.</summary>
    public string? Write(string path, string contents) =>
        Call("write_note", new JsonObject { ["path"] = path, ["content"] = contents })["commit"]?.GetValue<string>();

    public string? CreateFile(string path, string contents = "") =>
        Call("create_note", new JsonObject { ["path"] = path, ["content"] = contents })["commit"]?.GetValue<string>();

    public string? CreateFolder(string path) =>
        Call("create_folder", new JsonObject { ["path"] = path })["commit"]?.GetValue<string>();

    public string? Move(string from, string to) =>
        Call("move", new JsonObject { ["from"] = from, ["to"] = to })["commit"]?.GetValue<string>();

    public string? Delete(string path) =>
        Call("delete", new JsonObject { ["path"] = path })["commit"]?.GetValue<string>();

    public string? Undo(string commit) =>
        Call("undo", new JsonObject { ["commit"] = commit })["commit"]?.GetValue<string>();

    /// <summary>Relative path of <paramref name="fullPath"/> inside <paramref name="root"/>, which is the
    /// only form the vault accepts. Returns null if <paramref name="fullPath"/> is not under <paramref name="root"/>.</summary>
    public static string? RelativePath(string fullPath, string root)
    {
        string target = Path.GetFullPath(fullPath);
        string baseDir = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string prefix = baseDir + Path.DirectorySeparatorChar;

        return target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? target[prefix.Length..]
            : null;
    }
}
