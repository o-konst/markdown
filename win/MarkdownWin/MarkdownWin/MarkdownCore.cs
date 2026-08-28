//
//  MarkdownCore.cs
//  MarkdownWin
//
//  Managed facade over the shared Rust `markdown_core` library, which renders Markdown
//  and carries the compiled Vue web UI inside itself. Mirrors MarkdownCore.swift on macOS.
//

using System;
using System.Runtime.InteropServices;

namespace MarkdownWin;

/// <summary>A file of the web UI that was compiled into the Rust library.</summary>
internal sealed record WebAsset(byte[] Data, string MimeType);

internal static class MarkdownCore
{
    private const string Library = "markdown_core";

    [StructLayout(LayoutKind.Sequential)]
    private struct MdAsset
    {
        public IntPtr Data;
        public nuint Len;
        public IntPtr Mime;
    }

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr md_version();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern nuint md_asset_count();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr md_render([MarshalAs(UnmanagedType.LPUTF8Str)] string markdown);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void md_string_free(IntPtr value);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool md_asset_lookup(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        out MdAsset asset);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool md_asset_exists([MarshalAs(UnmanagedType.LPUTF8Str)] string path);

    #region Vault FFI

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr md_vault_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void md_vault_close(IntPtr vault);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr md_vault_call(
        IntPtr vault,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string inputJson);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr md_vault_tools();

    /// <summary>Opens the vault at <paramref name="path"/>. Returns <see cref="IntPtr.Zero"/> on failure.</summary>
    internal static IntPtr VaultOpen(string path) => IsAvailable ? md_vault_open(path) : IntPtr.Zero;

    /// <summary>Closes a vault opened by <see cref="VaultOpen"/>. Safe to call with a zero handle.</summary>
    internal static void VaultClose(IntPtr handle)
    {
        if (IsAvailable && handle != IntPtr.Zero)
        {
            md_vault_close(handle);
        }
    }

    /// <summary>
    /// Runs one vault tool. The reply is always a JSON object — a failing tool call is an
    /// ordinary non-null reply carrying <c>{"ok":false,"error":"..."}</c>, not a null result.
    /// </summary>
    internal static string? VaultCall(IntPtr handle, string name, string inputJson)
    {
        if (!IsAvailable)
        {
            return null;
        }

        IntPtr raw = md_vault_call(handle, name, inputJson);
        if (raw == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStringUTF8(raw);
        }
        finally
        {
            md_string_free(raw);
        }
    }

    #endregion

    #region Agent FFI

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr md_agent_open(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string vaultPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string apiKey);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void md_agent_close(IntPtr agent);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool md_agent_send_start(
        IntPtr agent,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string text);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr md_agent_poll_event(IntPtr agent);

    /// <summary>Opens a chat session against the vault at <paramref name="vaultPath"/>. Returns
    /// <see cref="IntPtr.Zero"/> if the vault path is unusable.</summary>
    internal static IntPtr AgentOpen(string vaultPath, string apiKey) =>
        IsAvailable ? md_agent_open(vaultPath, apiKey) : IntPtr.Zero;

    /// <summary>Closes a session opened by <see cref="AgentOpen"/>. Safe to call with a zero handle.</summary>
    internal static void AgentClose(IntPtr agent)
    {
        if (IsAvailable && agent != IntPtr.Zero)
        {
            md_agent_close(agent);
        }
    }

    /// <summary>Starts a turn. Returns false without starting anything if one is already running.</summary>
    internal static bool AgentSendStart(IntPtr agent, string text) =>
        IsAvailable && md_agent_send_start(agent, text);

    /// <summary>
    /// Blocks for the next event of the current turn, or returns null once the turn has
    /// finished. Must be called from a dedicated background thread, never the UI thread.
    /// </summary>
    internal static string? AgentPollEvent(IntPtr agent)
    {
        if (!IsAvailable)
        {
            return null;
        }

        IntPtr raw = md_agent_poll_event(agent);
        if (raw == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStringUTF8(raw);
        }
        finally
        {
            md_string_free(raw);
        }
    }

    #endregion

    private static bool? isAvailable;

    /// <summary>True when the native library could be loaded.</summary>
    public static bool IsAvailable
    {
        get
        {
            if (isAvailable is null)
            {
                try
                {
                    _ = md_asset_count();
                    isAvailable = true;
                }
                catch (DllNotFoundException)
                {
                    isAvailable = false;
                }
                catch (EntryPointNotFoundException)
                {
                    isAvailable = false;
                }
            }

            return isAvailable.Value;
        }
    }

    /// <summary>Version of the Rust core library.</summary>
    public static string Version =>
        IsAvailable ? Marshal.PtrToStringUTF8(md_version()) ?? string.Empty : string.Empty;

    /// <summary>Number of web UI files embedded in the Rust library.</summary>
    public static int AssetCount => IsAvailable ? (int)md_asset_count() : 0;

    /// <summary>Renders Markdown to an HTML fragment.</summary>
    public static string Render(string markdown)
    {
        if (!IsAvailable)
        {
            return string.Empty;
        }

        IntPtr rendered = md_render(markdown);
        if (rendered == IntPtr.Zero)
        {
            return string.Empty;
        }

        try
        {
            return Marshal.PtrToStringUTF8(rendered) ?? string.Empty;
        }
        finally
        {
            md_string_free(rendered);
        }
    }

    /// <summary>
    /// Looks up an embedded web UI file by URL path, e.g. <c>/assets/index.js</c>.
    /// Unknown paths resolve to <c>index.html</c>.
    /// </summary>
    public static WebAsset? Asset(string path)
    {
        if (!IsAvailable || !md_asset_lookup(path, out MdAsset asset) ||
            asset.Data == IntPtr.Zero || asset.Mime == IntPtr.Zero)
        {
            return null;
        }

        var data = new byte[(int)asset.Len];
        Marshal.Copy(asset.Data, data, 0, data.Length);
        return new WebAsset(data, Marshal.PtrToStringUTF8(asset.Mime) ?? "application/octet-stream");
    }

    /// <summary>
    /// Whether <paramref name="path"/> matches a real embedded web UI file exactly — unlike
    /// <see cref="Asset"/>, without its single-page-app fallback to <c>index.html</c>. Use
    /// this, not <see cref="Asset"/>, to tell "this is a genuine embedded UI route" apart from
    /// "nothing here" — <see cref="Asset"/> would otherwise always report success (as
    /// <c>index.html</c>) for literally any path.
    /// </summary>
    public static bool AssetExists(string path) => IsAvailable && md_asset_exists(path);
}
