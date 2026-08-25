//
//  SidebarView.xaml.cs
//  MarkdownWin
//
//  The folder tree, the search results that replace it while searching, and the account
//  row pinned to the bottom. Mirrors SidebarView.swift.
//

using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace MarkdownWin;

/// <summary>One flattened row of the file tree, at a given indentation depth.</summary>
internal sealed class FileRow
{
    public FileNode Node { get; }
    public int Depth { get; }

    public FileRow(FileNode node, int depth)
    {
        Node = node;
        Depth = depth;
    }

    public Thickness Indent => new(Depth * 16, 0, 0, 0);
    public string Icon => Node.IsDirectory ? "" : "";
    public string Chevron => Node.IsExpanded ? "" : "";
    public Visibility ChevronVisibility => Node.IsDirectory ? Visibility.Visible : Visibility.Collapsed;
}

internal sealed partial class SidebarView : UserControl
{
    public event EventHandler? OpenFolderRequested;
    public event EventHandler? SettingsRequested;
    public event EventHandler? LoginRequested;
    public event EventHandler? AssistantRequested;

    private Workspace? workspace;
    public Workspace? Workspace
    {
        get => workspace;
        set
        {
            if (workspace is not null)
            {
                workspace.PropertyChanged -= OnWorkspacePropertyChanged;
                workspace.SearchHits.CollectionChanged -= OnSearchHitsChanged;
            }

            workspace = value;

            if (workspace is not null)
            {
                workspace.PropertyChanged += OnWorkspacePropertyChanged;
                workspace.SearchHits.CollectionChanged += OnSearchHitsChanged;
                SearchResultsList.ItemsSource = workspace.SearchHits;
            }

            RenderState();
            RenderError();
        }
    }

    private Account? account;
    public Account? Account
    {
        get => account;
        set
        {
            if (account is not null)
            {
                account.PropertyChanged -= OnAccountPropertyChanged;
            }

            account = value;

            if (account is not null)
            {
                account.PropertyChanged += OnAccountPropertyChanged;
            }

            RenderAccount();
        }
    }

    public SidebarView()
    {
        InitializeComponent();
        RenderAccount();
    }

    private void OnOpenFolderClick(object sender, RoutedEventArgs e) => OpenFolderRequested?.Invoke(this, EventArgs.Empty);

    private void OnAssistantClick(object sender, RoutedEventArgs e) => AssistantRequested?.Invoke(this, EventArgs.Empty);

    private void OnWorkspacePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(MarkdownWin.Workspace.Root):
            case nameof(MarkdownWin.Workspace.IsSearchActive):
                RenderState();
                break;
            case nameof(MarkdownWin.Workspace.IsSearching):
            case nameof(MarkdownWin.Workspace.SearchQuery):
                RenderSearchResults();
                break;
            case nameof(MarkdownWin.Workspace.ErrorMessage):
                RenderError();
                break;
        }
    }

    private void OnSearchHitsChanged(object? sender, NotifyCollectionChangedEventArgs e) => RenderSearchResults();

    private void OnAccountPropertyChanged(object? sender, PropertyChangedEventArgs e) => RenderAccount();

    // MARK: - State

    private void RenderState()
    {
        if (workspace is not { } current)
        {
            SearchResultsPanel.Visibility = Visibility.Collapsed;
            FileTreeList.Visibility = Visibility.Collapsed;
            EmptyStatePanel.Visibility = Visibility.Visible;
            return;
        }

        if (current.IsSearchActive)
        {
            SearchResultsPanel.Visibility = Visibility.Visible;
            FileTreeList.Visibility = Visibility.Collapsed;
            EmptyStatePanel.Visibility = Visibility.Collapsed;
            RenderSearchResults();
        }
        else if (current.Root is not null)
        {
            SearchResultsPanel.Visibility = Visibility.Collapsed;
            FileTreeList.Visibility = Visibility.Visible;
            EmptyStatePanel.Visibility = Visibility.Collapsed;
            RenderFileTree();
        }
        else
        {
            SearchResultsPanel.Visibility = Visibility.Collapsed;
            FileTreeList.Visibility = Visibility.Collapsed;
            EmptyStatePanel.Visibility = Visibility.Visible;
        }
    }

    private void RenderSearchResults()
    {
        if (workspace is not { } current || !current.IsSearchActive)
        {
            return;
        }

        bool empty = current.SearchHits.Count == 0;
        SearchResultsList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        SearchEmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;

        if (empty)
        {
            SearchEmptyStateTitle.Text = current.IsSearching ? "Searching…" : "No Results";
            SearchEmptyStateDescription.Visibility = current.IsSearching ? Visibility.Collapsed : Visibility.Visible;
            SearchEmptyStateDescription.Text = $"Nothing matches \"{current.SearchQuery}\".";
        }
        else
        {
            int count = current.SearchHits.Count;
            SearchResultsHeader.Text = current.IsSearching
                ? "Searching…"
                : $"{count} result{(count == 1 ? string.Empty : "s")}";
        }
    }

    private void RenderFileTree()
    {
        if (workspace?.Root is not { } root)
        {
            FileTreeList.ItemsSource = null;
            return;
        }

        FileTreeHeader.Text = root.Name;
        FileTreeList.ItemsSource = Flatten(root.Children ?? new List<FileNode>(), 0);
    }

    private static List<FileRow> Flatten(IEnumerable<FileNode> nodes, int depth)
    {
        var rows = new List<FileRow>();
        foreach (FileNode node in nodes)
        {
            rows.Add(new FileRow(node, depth));
            if (node.IsDirectory && node.IsExpanded && node.Children is { } children)
            {
                rows.AddRange(Flatten(children, depth + 1));
            }
        }

        return rows;
    }

    private void RenderError()
    {
        string? message = workspace?.ErrorMessage;
        bool hasMessage = !string.IsNullOrEmpty(message);
        ErrorBanner.Visibility = hasMessage ? Visibility.Visible : Visibility.Collapsed;
        ErrorBannerText.Text = message ?? string.Empty;
    }

    private void RenderAccount()
    {
        if (account is { IsLoggedIn: true } current)
        {
            AccountAvatar.Initials = current.Initials;
            AccountNameText.Text = current.FullName;
            AccountEmailText.Text = current.Email;
            AccountEmailText.Visibility = string.IsNullOrEmpty(current.Email) ? Visibility.Collapsed : Visibility.Visible;
        }
        else
        {
            AccountAvatar.Initials = string.Empty;
            AccountNameText.Text = "Not signed in";
            AccountEmailText.Visibility = Visibility.Collapsed;
        }
    }

    // MARK: - Tree interaction

    private void OnChevronTapped(object sender, TappedRoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not FileRow row || !row.Node.IsDirectory)
        {
            return;
        }

        row.Node.IsExpanded = !row.Node.IsExpanded;
        if (row.Node.IsExpanded)
        {
            row.Node.LoadChildren();
        }

        RenderFileTree();
        e.Handled = true;
    }

    private async void OnFileTreeSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (FileTreeList.SelectedItem is not FileRow row)
        {
            return;
        }

        if (row.Node.IsDirectory)
        {
            // Directory rows toggle expansion rather than "select."
            FileTreeList.SelectedItem = null;
            row.Node.IsExpanded = !row.Node.IsExpanded;
            if (row.Node.IsExpanded)
            {
                row.Node.LoadChildren();
            }

            RenderFileTree();
            return;
        }

        if (workspace is { } current)
        {
            await current.SelectFileAsync(row.Node.Path);
        }
    }

    private void OnFileTreeRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not FileRow row)
        {
            return;
        }

        var flyout = new MenuFlyout();
        var refresh = new MenuFlyoutItem { Text = "Refresh" };
        refresh.Click += (_, _) =>
        {
            row.Node.Reload();
            RenderFileTree();
        };
        flyout.Items.Add(refresh);
        flyout.ShowAt((FrameworkElement)sender, e.GetPosition((FrameworkElement)sender));
    }

    private async void OnSearchResultSelected(object sender, SelectionChangedEventArgs e)
    {
        if (SearchResultsList.SelectedItem is not SearchHit hit || workspace is not { } current)
        {
            return;
        }

        await current.SelectFileAsync(hit.Path);
    }

    // MARK: - Account menu

    private void OnAccountFlyoutOpening(object? sender, object e)
    {
        AccountFlyout.Items.Clear();

        if (account is { IsLoggedIn: true })
        {
            AddFlyoutItem("Settings…", () => SettingsRequested?.Invoke(this, EventArgs.Empty));
            AccountFlyout.Items.Add(new MenuFlyoutSeparator());
            AddFlyoutItem("Log Out", () =>
            {
                account?.LogOut();
                RenderAccount();
            });
        }
        else
        {
            AddFlyoutItem("Log In…", () => LoginRequested?.Invoke(this, EventArgs.Empty));
            AddFlyoutItem("Settings…", () => SettingsRequested?.Invoke(this, EventArgs.Empty));
        }
    }

    private void AddFlyoutItem(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        AccountFlyout.Items.Add(item);
    }
}
