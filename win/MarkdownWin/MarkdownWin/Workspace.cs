//
//  Workspace.cs
//  MarkdownWin
//
//  The opened folder, the file shown in the editor, and the state that keeps both in sync.
//  Mirrors Workspace.swift.
//
//  Edits are saved for you: typing schedules a debounced write, and switching files or
//  closing the folder flushes first. Nothing is written directly to disk — every change goes
//  through VaultStore, so it is committed to the vault's history and can be undone.
//
//  Unlike the Swift version (whose FFI calls run synchronously on an already-busy main
//  thread), vault calls here are wrapped in Task.Run to keep the UI responsive. That
//  reintroduces a race Swift never had — a rapid file switch could let an old flush land
//  after a new file has already loaded — so a SemaphoreSlim serializes every vault-touching
//  operation (flush, load, and nothing else needs it: search never touches the vault, see
//  FolderSearch.cs).
//

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace MarkdownWin;

internal sealed class Workspace : ObservableBase
{
    public const string UntitledText = "Hello, world!";

    private readonly SemaphoreSlim vaultGate = new(1, 1);

    private FileNode? root;
    public FileNode? Root
    {
        get => root;
        private set => Set(ref root, value);
    }

    /// <summary>The file the editor is showing, as a full path. Use <see cref="SelectFileAsync"/> to change it.</summary>
    private string? selectedFile;
    public string? SelectedFile
    {
        get => selectedFile;
        private set
        {
            if (Set(ref selectedFile, value))
            {
                Notify(nameof(DocumentTitle));
            }
        }
    }

    private string text = UntitledText;
    public string Text
    {
        get => text;
        set
        {
            if (!Set(ref text, value))
            {
                return;
            }

            ScheduleAutosave();
        }
    }

    /// <summary>True while the editor holds changes that are not on disk yet.</summary>
    private bool hasUnsavedChanges;
    public bool HasUnsavedChanges
    {
        get => hasUnsavedChanges;
        private set => Set(ref hasUnsavedChanges, value);
    }

    /// <summary>Set when the last open attempt (or save, or load) failed; shown under the sidebar tree.</summary>
    private string? errorMessage;
    public string? ErrorMessage
    {
        get => errorMessage;
        private set => Set(ref errorMessage, value);
    }

    /// <summary>Typed into the toolbar's search field; drives <see cref="SearchHits"/>.</summary>
    private string searchQuery = string.Empty;
    public string SearchQuery
    {
        get => searchQuery;
        set
        {
            if (searchQuery == value)
            {
                return;
            }

            searchQuery = value;
            Notify();
            Notify(nameof(IsSearchActive));
            RestartSearch();
        }
    }

    public ObservableCollection<SearchHit> SearchHits { get; } = new();

    private bool isSearching;
    public bool IsSearching
    {
        get => isSearching;
        private set => Set(ref isSearching, value);
    }

    public bool IsSearchActive => searchQuery.Trim().Length > 0;

    public string? FolderName => Root?.Name;

    public string DocumentTitle => SelectedFile is { } path ? Path.GetFileName(path) : "Untitled";

    /// <summary>The in-flight search, cancelled whenever the query changes again.</summary>
    private CancellationTokenSource? searchCts;

    /// <summary>Opened on the first write rather than on open, so browsing a folder leaves no
    /// trace — in particular, no `.git` directory appears until something actually changes.</summary>
    private VaultStore? vault;

    /// <summary>The pending debounced save, cancelled by each further keystroke.</summary>
    private CancellationTokenSource? autosaveCts;

    /// <summary>Watches for changes made outside the app — by an MCP client, or another editor.</summary>
    private VaultWatcher? watcher;

    public async Task OpenAsync(string folder)
    {
        await FlushPendingSaveAsync(SelectedFile);
        watcher?.Stop();
        watcher = null;
        vault?.Dispose();
        vault = null;
        ErrorMessage = null;

        var node = new FileNode(folder, isDirectory: true);
        node.LoadChildren();
        node.IsExpanded = true;

        Root = node;
        SelectedFile = null;
        Text = UntitledText;
        Notify(nameof(FolderName));

        RestartSearch();

        watcher = new VaultWatcher(folder, changed => AbsorbExternalChanges(changed));
    }

    public async Task CloseFolderAsync()
    {
        await FlushPendingSaveAsync(SelectedFile);
        watcher?.Stop();
        watcher = null;
        vault?.Dispose();
        vault = null;

        searchCts?.Cancel();
        searchCts = null;
        searchQuery = string.Empty;
        Notify(nameof(SearchQuery));
        Notify(nameof(IsSearchActive));
        SearchHits.Clear();
        IsSearching = false;

        Root = null;
        SelectedFile = null;
        ErrorMessage = null;
        Text = UntitledText;
        Notify(nameof(FolderName));
    }

    /// <summary>Flushes the previously-selected file's pending save, then loads the new one from disk.</summary>
    public async Task SelectFileAsync(string? path)
    {
        if (path == SelectedFile)
        {
            return;
        }

        string? previous = SelectedFile;
        await FlushPendingSaveAsync(previous);
        SelectedFile = path;
        await LoadSelectedFileAsync();
    }

    public void ReportOpenFailure(Exception error) => ErrorMessage = error.Message;

    /// <summary>Public explicit flush-now entry point.</summary>
    public Task SaveAsync() => FlushPendingSaveAsync(SelectedFile);

    // MARK: - Search

    /// <summary>Debounced so a burst of keystrokes only reads the folder once.</summary>
    private void RestartSearch()
    {
        searchCts?.Cancel();

        if (Root is not { } currentRoot || !IsSearchActive)
        {
            searchCts = null;
            SearchHits.Clear();
            IsSearching = false;
            return;
        }

        string query = SearchQuery;
        IsSearching = true;
        var cts = searchCts = new CancellationTokenSource();
        _ = RunSearchAsync(currentRoot.Path, query, cts.Token);
    }

    private async Task RunSearchAsync(string root, string query, CancellationToken token)
    {
        try
        {
            await Task.Delay(250, token);
        }
        catch (TaskCanceledException)
        {
            return;
        }

        if (token.IsCancellationRequested)
        {
            return;
        }

        List<SearchHit> hits;
        try
        {
            hits = await FolderSearch.RunAsync(root, query, token);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        if (token.IsCancellationRequested)
        {
            return;
        }

        SearchHits.Clear();
        foreach (SearchHit hit in hits)
        {
            SearchHits.Add(hit);
        }

        IsSearching = false;
    }

    // MARK: - Changes from outside the app

    /// <summary>Folds in changes another writer made: refresh the tree, and reload the open
    /// file when doing so cannot lose anything.</summary>
    private void AbsorbExternalChanges(IReadOnlyList<string> changed)
    {
        Root?.Refresh();

        if (IsSearchActive)
        {
            RestartSearch();
        }

        if (SelectedFile is not { } current)
        {
            return;
        }

        bool matchesOpenFile = false;
        foreach (string path in changed)
        {
            if (string.Equals(Path.GetFullPath(path), Path.GetFullPath(current), StringComparison.OrdinalIgnoreCase))
            {
                matchesOpenFile = true;
                break;
            }
        }

        if (!matchesOpenFile)
        {
            return;
        }

        // Never overwrite what the person is in the middle of typing. Their copy stays; the
        // conflict is surfaced instead of being resolved by whoever wrote last.
        if (HasUnsavedChanges)
        {
            ErrorMessage = $"{Path.GetFileName(current)} also changed outside the app. "
                + "Your unsaved edits are still here; saving will overwrite the other change.";
            return;
        }

        _ = LoadSelectedFileAsync();
    }

    // MARK: - Saving

    private void ScheduleAutosave()
    {
        // The untitled scratch buffer has nowhere to go until a file is chosen.
        if (SelectedFile is null)
        {
            return;
        }

        HasUnsavedChanges = true;

        autosaveCts?.Cancel();
        var cts = autosaveCts = new CancellationTokenSource();
        _ = FlushAfterDelayAsync(cts.Token);
    }

    private async Task FlushAfterDelayAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(800, token);
        }
        catch (TaskCanceledException)
        {
            return;
        }

        if (token.IsCancellationRequested)
        {
            return;
        }

        await FlushPendingSaveAsync(SelectedFile);
    }

    /// <summary>Writes the current buffer to <paramref name="url"/>, which may be a file we
    /// have just navigated away from — hence the explicit argument rather than reading
    /// <see cref="SelectedFile"/>.</summary>
    private async Task FlushPendingSaveAsync(string? url)
    {
        autosaveCts?.Cancel();
        autosaveCts = null;

        if (!HasUnsavedChanges || url is null || RelativePath(url) is not { } relative)
        {
            return;
        }

        string contents = Text;
        await vaultGate.WaitAsync();
        try
        {
            await Task.Run(() => GetOrOpenVault().Write(relative, contents));
            HasUnsavedChanges = false;
            ErrorMessage = null;
        }
        catch (Exception error) when (error is VaultException or IOException)
        {
            // Keep HasUnsavedChanges set: the next keystroke or switch will try again.
            ErrorMessage = $"Could not save {Path.GetFileName(url)}: {error.Message}";
        }
        finally
        {
            vaultGate.Release();
        }
    }

    /// <summary>Opens the vault on demand. See <see cref="vault"/> for why this is not done
    /// when the folder opens.</summary>
    private VaultStore GetOrOpenVault()
    {
        if (vault is { } existing)
        {
            return existing;
        }

        if (Root is not { } currentRoot)
        {
            throw new VaultException(VaultErrorKind.MalformedReply, "No folder is open.");
        }

        var opened = new VaultStore(currentRoot.Path);
        vault = opened;
        return opened;
    }

    private string? RelativePath(string url)
    {
        if (Root is not { } currentRoot)
        {
            return null;
        }

        return VaultStore.RelativePath(url, currentRoot.Path);
    }

    private async Task LoadSelectedFileAsync()
    {
        if (SelectedFile is not { } url)
        {
            return;
        }

        await vaultGate.WaitAsync();
        try
        {
            Text = await Task.Run(() => File.ReadAllText(url, System.Text.Encoding.UTF8));
            // Assigning Text scheduled a save; the file is what is on disk, so cancel it.
            autosaveCts?.Cancel();
            autosaveCts = null;
            HasUnsavedChanges = false;
            ErrorMessage = null;
        }
        catch (IOException error)
        {
            ErrorMessage = $"Could not read {Path.GetFileName(url)}: {error.Message}";
        }
        finally
        {
            vaultGate.Release();
        }
    }
}
