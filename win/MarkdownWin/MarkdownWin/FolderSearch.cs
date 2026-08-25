//
//  FolderSearch.cs
//  MarkdownWin
//
//  Searches the open folder by file name and file contents. Mirrors FolderSearch.swift.
//
//  Deliberately does NOT go through the vault: md_vault_open() initialises git history and
//  records a baseline commit the first time a given path is opened, so routing search through
//  it would create a `.git` folder just from browsing — exactly what Workspace defers vault
//  access to avoid (see Workspace.GetOrOpenVault). This runs entirely off the UI thread.
//

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace MarkdownWin;

internal static class FolderSearch
{
    /// Stops one enormous file from stalling a search.
    private const long MaxFileBytes = 4 * 1024 * 1024;

    /// Matching lines kept per file.
    private const int MaxSnippetsPerFile = 3;

    /// Enough to fill the sidebar many times over; beyond this the query is too broad.
    private const int MaxHits = 200;

    private const int SnippetLimit = 160;

    /// <summary>Finds files whose name or contents contain <paramref name="query"/>.</summary>
    public static Task<List<SearchHit>> RunAsync(string root, string query, CancellationToken token) =>
        Task.Run(() => Run(root, query, token), token);

    private static List<SearchHit> Run(string root, string query, CancellationToken token)
    {
        string needle = query.Trim();
        if (needle.Length == 0)
        {
            return new List<SearchHit>();
        }

        var hits = new List<SearchHit>();

        foreach (string path in Candidates(root))
        {
            token.ThrowIfCancellationRequested();
            if (hits.Count >= MaxHits)
            {
                break;
            }

            long size;
            try
            {
                size = new FileInfo(path).Length;
            }
            catch (IOException)
            {
                continue;
            }

            bool nameMatched = Path.GetFileName(path).Contains(needle, StringComparison.CurrentCultureIgnoreCase);
            List<string> snippets = size <= MaxFileBytes ? MatchingLines(path, needle) : new List<string>();

            if (nameMatched || snippets.Count > 0)
            {
                hits.Add(new SearchHit(path, nameMatched, snippets));
            }
        }

        // Name matches first, then alphabetically, so results do not jump around.
        return hits
            .OrderByDescending(hit => hit.NameMatched)
            .ThenBy(hit => hit.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    /// <summary>Every Markdown file under <paramref name="root"/>, deepest paths included.</summary>
    private static IEnumerable<string> Candidates(string root)
    {
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
        };

        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(root, "*", options);
        }
        catch (IOException)
        {
            return Enumerable.Empty<string>();
        }

        return files.Where(MarkdownFile.Matches);
    }

    private static List<string> MatchingLines(string path, string needle)
    {
        string[] lines;
        try
        {
            lines = File.ReadAllLines(path);
        }
        catch (IOException)
        {
            return new List<string>();
        }
        catch (UnauthorizedAccessException)
        {
            return new List<string>();
        }

        var snippets = new List<string>();
        foreach (string line in lines)
        {
            if (!line.Contains(needle, StringComparison.CurrentCultureIgnoreCase))
            {
                continue;
            }

            string trimmed = line.Trim();
            snippets.Add(trimmed.Length > SnippetLimit ? trimmed[..SnippetLimit] : trimmed);
            if (snippets.Count == MaxSnippetsPerFile)
            {
                break;
            }
        }

        return snippets;
    }
}
