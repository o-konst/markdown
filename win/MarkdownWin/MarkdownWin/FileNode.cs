//
//  FileNode.cs
//  MarkdownWin
//
//  Model behind the sidebar folder tree. Mirrors FileNode.swift.
//

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace MarkdownWin;

/// <summary>Markdown-flavored file kinds — used for the "Open File…" picker and for routing
/// a dropped file to open-as-document vs. reporting it unsupported. The sidebar tree itself
/// shows every file and folder, hidden ones (<c>.git</c>, <c>.gitignore</c>, …) included.</summary>
internal static class MarkdownFile
{
    private static readonly HashSet<string> Extensions =
        new(StringComparer.OrdinalIgnoreCase) { ".md", ".markdown", ".mdown", ".mkd", ".mdx", ".text", ".txt" };

    /// <summary>The recognised extensions, for <c>FileOpenPicker.FileTypeFilter</c>.</summary>
    public static IReadOnlyCollection<string> PickerExtensions => Extensions;

    public static bool Matches(string path) => Extensions.Contains(Path.GetExtension(path));
}

/// <summary>One row of the folder tree.</summary>
///
/// <remarks>
/// A directory reads its contents the first time it is expanded, so opening a folder with a
/// deep hierarchy only touches the levels that are actually on screen.
/// </remarks>
internal sealed class FileNode
{
    public string Path { get; }
    public bool IsDirectory { get; }
    public string Name => System.IO.Path.GetFileName(Path.TrimEnd('\\', '/'));

    /// <summary>Null until <see cref="LoadChildren"/> has been called once.</summary>
    public List<FileNode>? Children { get; private set; }

    public bool IsExpanded { get; set; }

    public FileNode(string path, bool isDirectory)
    {
        Path = path;
        IsDirectory = isDirectory;
    }

    /// <summary>Fails (returns null) when <paramref name="path"/> cannot be inspected.</summary>
    public static FileNode? Create(string path)
    {
        try
        {
            bool isDirectory = File.GetAttributes(path).HasFlag(FileAttributes.Directory);
            return new FileNode(path, isDirectory);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Reads the directory once; later calls do nothing.</summary>
    public void LoadChildren()
    {
        if (!IsDirectory || Children is not null)
        {
            return;
        }

        Children = Contents(Path);
    }

    /// <summary>Drops the cached contents so the next expansion re-reads the directory.</summary>
    public void Reload()
    {
        Children = null;
        LoadChildren();
    }

    /// <summary>
    /// Re-reads the directory, keeping the node objects that are still there.
    /// </summary>
    /// <remarks>
    /// Merging rather than rebuilding is what makes external changes bearable: replacing every
    /// child instance would collapse every expanded folder in the tree whenever anything
    /// changed anywhere. Directories that were never expanded stay unread.
    /// </remarks>
    public void Refresh()
    {
        if (!IsDirectory || Children is not { } existing)
        {
            return;
        }

        Dictionary<string, FileNode> kept = new(StringComparer.OrdinalIgnoreCase);
        foreach (FileNode node in existing)
        {
            kept.TryAdd(node.Path, node);
        }

        List<FileNode> fresh = Contents(Path);
        Children = fresh
            .Select(node => kept.TryGetValue(node.Path, out FileNode? previous) && previous.IsDirectory == node.IsDirectory
                ? previous
                : node)
            .ToList();

        // Only recurse where contents are already on screen.
        foreach (FileNode child in Children.Where(child => child.IsDirectory && child.Children is not null))
        {
            child.Refresh();
        }
    }

    private static List<FileNode> Contents(string directory)
    {
        IEnumerable<string> entries;
        try
        {
            entries = Directory.EnumerateFileSystemEntries(directory);
        }
        catch (IOException)
        {
            return new List<FileNode>();
        }
        catch (UnauthorizedAccessException)
        {
            return new List<FileNode>();
        }

        return entries
            .Select(Create)
            .Where(node => node is not null)
            .Select(node => node!)
            .OrderByDescending(node => node.IsDirectory)
            .ThenBy(node => node.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }
}
