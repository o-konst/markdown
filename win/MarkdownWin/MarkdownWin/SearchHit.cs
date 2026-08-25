//
//  SearchHit.cs
//  MarkdownWin
//
//  One matching file, with the lines that matched. Mirrors FolderSearch.swift's SearchHit.
//

namespace MarkdownWin;

internal sealed record SearchHit(string Path, bool NameMatched, System.Collections.Generic.IReadOnlyList<string> Snippets)
{
    public string Name => System.IO.Path.GetFileName(Path);
}
