//
//  VaultWatcher.cs
//  MarkdownWin
//
//  Watches the open folder so changes made outside the app show up in it. Mirrors
//  VaultWatcher.swift (which uses FSEvents on macOS; this uses FileSystemWatcher).
//
//  This matters more than it used to: the bundled MCP server lets Claude Code and Claude
//  Desktop write into the same vault while the app is open, and an editor that silently
//  showed stale content would be worse than one with no integration at all.
//

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;

namespace MarkdownWin;

internal sealed class VaultWatcher : IDisposable
{
    /// Coalescing window. Long enough that a burst of writes is one notification, short
    /// enough that a change feels immediate.
    private const int DebounceMs = 300;

    private readonly FileSystemWatcher watcher;
    private readonly DispatcherQueue dispatcherQueue;
    private readonly Action<IReadOnlyList<string>> onChange;
    private readonly object gate = new();
    private HashSet<string>? pending;
    private CancellationTokenSource? debounceCts;
    private bool disposed;

    public VaultWatcher(string root, Action<IReadOnlyList<string>> onChange)
    {
        this.onChange = onChange;
        dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        watcher = new FileSystemWatcher(root)
        {
            IncludeSubdirectories = true,
            InternalBufferSize = 64 * 1024,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite,
        };
        watcher.Changed += (_, e) => Enqueue(e.FullPath);
        watcher.Created += (_, e) => Enqueue(e.FullPath);
        watcher.Deleted += (_, e) => Enqueue(e.FullPath);
        watcher.Renamed += (_, e) => { Enqueue(e.OldFullPath); Enqueue(e.FullPath); };
        // A buffer overflow means some events were lost; treat it as "something under root
        // changed" rather than trying to reconstruct exactly what.
        watcher.Error += (_, _) => Enqueue(root);
        watcher.EnableRaisingEvents = true;
    }

    public void Stop() => Dispose();

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        watcher.EnableRaisingEvents = false;
        watcher.Dispose();
        debounceCts?.Cancel();
    }

    private void Enqueue(string path)
    {
        // Committing rewrites `.git` constantly; those are our own bookkeeping, not notes.
        string normalized = path.Replace('\\', '/');
        if (normalized.Contains("/.git/") || normalized.EndsWith("/.git", StringComparison.Ordinal))
        {
            return;
        }

        CancellationTokenSource cts;
        lock (gate)
        {
            (pending ??= new HashSet<string>()).Add(path);
            debounceCts?.Cancel();
            cts = debounceCts = new CancellationTokenSource();
        }

        _ = DebounceAsync(cts.Token);
    }

    private async Task DebounceAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(DebounceMs, token);
        }
        catch (TaskCanceledException)
        {
            return;
        }

        List<string> batch;
        lock (gate)
        {
            if (pending is not { Count: > 0 } current)
            {
                return;
            }

            batch = current.ToList();
            pending = null;
        }

        dispatcherQueue.TryEnqueue(() => onChange(batch));
    }
}
