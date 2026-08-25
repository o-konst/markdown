//
//  MainWindow.xaml.cs
//  MarkdownWin
//
//  The Windows counterpart of ContentView.swift / MarkdownApp.swift: a sidebar over a folder
//  vault, with a live preview and an overlay-toggle raw editor.
//

using System;
using System.ComponentModel;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MarkdownWin;

public sealed partial class MainWindow : Window
{
    private readonly Workspace workspace = new();
    private readonly Account account = new();

    private bool isUpdatingEditor;
    private bool isDialogShowing;
    private bool isOutlineAvailable;

    private bool isDraggingDivider;
    private double dragStartX;
    private double dragStartWidth;

    public MainWindow()
    {
        InitializeComponent();

        Sidebar.Workspace = workspace;
        Sidebar.Account = account;
        Sidebar.OpenFolderRequested += (_, _) => _ = OpenFolderAsync();
        Sidebar.SettingsRequested += (_, _) => _ = ShowSettingsAsync();
        Sidebar.LoginRequested += (_, _) => _ = ShowLoginAsync();
        Sidebar.AssistantRequested += OnAssistantRequested;

        workspace.PropertyChanged += OnWorkspacePropertyChanged;
        Preview.OutlineAvailabilityChanged += (_, available) => isOutlineAvailable = available;
        Preview.CoreWebView2Ready += (_, _) => ApplyTheme();

        UpdateTitle();
        ApplyTheme();
        Preview.SetPreferences(AppSettings.CurrentPreferences());
    }

    private void OnWorkspacePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(Workspace.Text):
                Preview.SetDocumentText(workspace.Text);
                if (EditorOverlay.Visibility == Visibility.Visible)
                {
                    isUpdatingEditor = true;
                    EditorOverlay.Text = workspace.Text;
                    isUpdatingEditor = false;
                }

                break;

            case nameof(Workspace.DocumentTitle):
                UpdateTitle();
                break;

            case nameof(Workspace.Root):
                CloseFolderButton.IsEnabled = workspace.Root is not null;
                break;
        }
    }

    private void UpdateTitle() => Title = $"{workspace.DocumentTitle} — Markdown";

    private void OnEditorTextChanged(object sender, TextChangedEventArgs e)
    {
        if (isUpdatingEditor)
        {
            return;
        }

        workspace.Text = EditorOverlay.Text;
    }

    /// <summary>
    /// The preview always renders; the editor is layered over it on demand, so toggling edit
    /// mode does not tear down the web view and reload the whole web UI.
    /// </summary>
    private void OnEditToggleChanged(object sender, RoutedEventArgs e)
    {
        bool isEditing = EditToggle.IsChecked == true;
        if (isEditing)
        {
            isUpdatingEditor = true;
            EditorOverlay.Text = workspace.Text;
            isUpdatingEditor = false;
        }

        EditorOverlay.Visibility = isEditing ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput)
        {
            return;
        }

        workspace.SearchQuery = sender.Text;
    }

    private void OnOpenFolderClick(object sender, RoutedEventArgs e) => _ = OpenFolderAsync();

    private async Task OpenFolderAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        // FolderPicker requires at least one filter entry even though it only picks folders.
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (folder is null)
        {
            return;
        }

        try
        {
            await workspace.OpenAsync(folder.Path);
        }
        catch (Exception exception)
        {
            workspace.ReportOpenFailure(exception);
        }
    }

    private void OnCloseFolderClick(object sender, RoutedEventArgs e) => _ = workspace.CloseFolderAsync();

    private async Task ShowSettingsAsync()
    {
        var dialog = new SettingsDialog(isOutlineAvailable);
        dialog.PreferencesChanged += OnPreferencesChanged;
        try
        {
            await ShowDialogAsync(dialog);
        }
        finally
        {
            dialog.PreferencesChanged -= OnPreferencesChanged;
        }
    }

    private void OnPreferencesChanged(object? sender, EventArgs e)
    {
        Preview.SetPreferences(AppSettings.CurrentPreferences());
        ApplyTheme();
    }

    /// <summary>
    /// Applies the appearance setting to both the native window (so chrome follows it) and
    /// the hosted web content (which does not pick up `RequestedTheme` changes on its own).
    /// </summary>
    private void ApplyTheme()
    {
        ElementTheme theme = AppSettings.Appearance switch
        {
            AppAppearance.Light => ElementTheme.Light,
            AppAppearance.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };

        if (Content is FrameworkElement root)
        {
            root.RequestedTheme = theme;
        }

        Preview.SetColorScheme(theme);
    }

    private Task ShowLoginAsync() => ShowDialogAsync(new LoginDialog(account));

    private void OnAssistantRequested(object? sender, EventArgs e) => _ = ShowAssistantAsync();

    private async Task ShowAssistantAsync()
    {
        if (isDialogShowing)
        {
            return;
        }

        // A fresh ChatView/ChatViewModel each time, matching SwiftUI's actual behavior: its
        // ChatView is a struct re-instantiated by the sheet on every presentation, so the
        // transcript does not persist across closes on macOS either.
        var chat = new ChatView { VaultRoot = workspace.Root?.Path };
        var dialog = new ContentDialog
        {
            Content = chat,
            XamlRoot = Content.XamlRoot,
        };
        chat.DoneRequested += (_, _) => dialog.Hide();

        isDialogShowing = true;
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            isDialogShowing = false;
            chat.ViewModel.Dispose();
        }
    }

    private async Task ShowDialogAsync(ContentDialog dialog)
    {
        if (isDialogShowing)
        {
            return;
        }

        isDialogShowing = true;
        dialog.XamlRoot = Content.XamlRoot;
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            isDialogShowing = false;
        }
    }

    // MARK: - Sidebar divider

    private void OnDividerPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        isDraggingDivider = true;
        dragStartX = e.GetCurrentPoint(ContentGrid).Position.X;
        dragStartWidth = SidebarColumn.ActualWidth;
        ((UIElement)sender).CapturePointer(e.Pointer);
    }

    private void OnDividerPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!isDraggingDivider)
        {
            return;
        }

        double x = e.GetCurrentPoint(ContentGrid).Position.X;
        double newWidth = Math.Clamp(dragStartWidth + (x - dragStartX), 200, 420);
        SidebarColumn.Width = new GridLength(newWidth);
    }

    private void OnDividerPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        isDraggingDivider = false;
        ((UIElement)sender).ReleasePointerCapture(e.Pointer);
    }
}
