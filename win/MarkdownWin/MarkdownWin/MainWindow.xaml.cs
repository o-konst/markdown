//
//  MainWindow.xaml.cs
//  MarkdownWin
//
//  The Windows counterpart of ContentView.swift / MarkdownApp.swift: a sidebar over a folder
//  vault, with a live preview and an overlay-toggle raw editor.
//

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
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

    /// <summary>The formatting toolbar's last-applied snapshot — reapplied (for its
    /// enabled/disabled state only) whenever the Source toggle changes, since that's a
    /// purely-native concern the web view's own EditorToolbarState has no visibility into.</summary>
    private EditorToolbarState toolbarState = EditorToolbarState.Initial;

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
        Preview.DocumentEdited += (_, newText) => workspace.Text = newText;
        Preview.EditorStateChanged += (_, state) => ApplyToolbarState(state);
        workspace.FlushEditorPendingEdit = () => Preview.FlushPendingEditAsync();

        UpdateTitle();
        ApplyTheme();
        ApplyToolbarState(EditorToolbarState.Initial);
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

        // A plain-text overlay showing while the WYSIWYG editor is (invisibly) still there
        // underneath is not a state where formatting commands make sense to offer — matches
        // macOS's isSourceViewShowing check in EditorFormattingToolbar.swift.
        ApplyToolbarState(toolbarState);
    }

    // MARK: - Formatting toolbar

    /// <summary>Applies a freshly-reported <see cref="EditorToolbarState"/> to every toolbar
    /// button's checked/enabled state and the heading/mode labels. Also re-run (with the same
    /// state) whenever the Source toggle changes, since availability additionally depends on
    /// that purely-native concern.</summary>
    private void ApplyToolbarState(EditorToolbarState state)
    {
        toolbarState = state;
        bool isAvailable = state.IsEditable && EditToggle.IsChecked != true;

        bool isEdit = state.Mode == EditorMode.Edit;
        ModeToggle.IsChecked = isEdit;
        ModeToggle.Label = isEdit ? "Reading View" : "Edit";
        ModeToggleIcon.Glyph = isEdit ? "\uE890" : "\uE70F";
        ToolTipService.SetToolTip(ModeToggle, isEdit ? "Switch to Reading view" : "Switch to Edit mode");

        BoldButton.IsChecked = state.ActiveMarks.Contains(EditorMark.Bold);
        ItalicButton.IsChecked = state.ActiveMarks.Contains(EditorMark.Italic);
        StrikeButton.IsChecked = state.ActiveMarks.Contains(EditorMark.Strike);
        CodeMarkButton.IsChecked = state.ActiveMarks.Contains(EditorMark.Code);
        BoldButton.IsEnabled = isAvailable;
        ItalicButton.IsEnabled = isAvailable;
        StrikeButton.IsEnabled = isAvailable;
        CodeMarkButton.IsEnabled = isAvailable;

        BlockquoteButton.IsChecked = state.ActiveBlock == EditorBlock.Blockquote;
        BulletListButton.IsChecked = state.ActiveBlock == EditorBlock.BulletList;
        OrderedListButton.IsChecked = state.ActiveBlock == EditorBlock.OrderedList;
        TaskListButton.IsChecked = state.ActiveBlock == EditorBlock.TaskList;
        CodeBlockButton.IsChecked = state.ActiveBlock == EditorBlock.CodeBlock;
        BlockquoteButton.IsEnabled = isAvailable;
        BulletListButton.IsEnabled = isAvailable;
        OrderedListButton.IsEnabled = isAvailable;
        TaskListButton.IsEnabled = isAvailable;
        CodeBlockButton.IsEnabled = isAvailable;

        HeadingButton.Label = state.HeadingLevel is { } level ? $"H{level}" : "Text";
        HeadingButton.IsEnabled = isAvailable;
        HorizontalRuleButton.IsEnabled = isAvailable;

        LinkButton.IsEnabled = isAvailable;
        ImageButton.IsEnabled = isAvailable;
        FootnoteButton.IsEnabled = isAvailable;
    }

    private void OnModeToggleClick(object sender, RoutedEventArgs e)
    {
        bool requestEdit = ModeToggle.IsChecked != true;
        _ = Preview.RunEditorCommandAsync("setMode", new JsonObject { ["mode"] = requestEdit ? "edit" : "reading" });
    }

    /// <summary>Shared by every mark/block toggle button — each carries its
    /// `formatCommands.ts` command name as its <c>Tag</c>, mirroring macOS's
    /// `markCommand`/`blockCommand` lookup tables.</summary>
    private void OnMarkOrBlockButtonClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is string command)
        {
            _ = Preview.RunEditorCommandAsync(command);
        }
    }

    private void OnHeadingLevelClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not string raw || !int.TryParse(raw, out int level))
        {
            return;
        }

        JsonNode? levelValue = level == 0 ? null : JsonValue.Create(level);
        _ = Preview.RunEditorCommandAsync("setHeading", new JsonObject { ["level"] = levelValue });
    }

    private void OnHorizontalRuleClick(object sender, RoutedEventArgs e) =>
        _ = Preview.RunEditorCommandAsync("setHorizontalRule");

    private void OnLinkFlyoutOpening(object? sender, object e)
    {
        LinkUrlBox.Text = string.Empty;
        RemoveLinkButton.Visibility = toolbarState.LinkActive ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnLinkUrlKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            ApplyLink();
        }
    }

    private void OnApplyLinkClick(object sender, RoutedEventArgs e) => ApplyLink();

    private void ApplyLink()
    {
        string trimmed = LinkUrlBox.Text.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }

        _ = Preview.RunEditorCommandAsync("toggleLink", new JsonObject { ["href"] = trimmed });
        LinkFlyout.Hide();
    }

    private void OnRemoveLinkClick(object sender, RoutedEventArgs e)
    {
        _ = Preview.RunEditorCommandAsync("toggleLink");
        LinkFlyout.Hide();
    }

    private void OnImageFlyoutOpening(object? sender, object e) => ImageUrlBox.Text = string.Empty;

    private void OnImageUrlKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            ApplyImage();
        }
    }

    private void OnApplyImageClick(object sender, RoutedEventArgs e) => ApplyImage();

    private void ApplyImage()
    {
        string trimmed = ImageUrlBox.Text.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }

        _ = Preview.RunEditorCommandAsync("setImage", new JsonObject { ["src"] = trimmed });
        ImageButton.Flyout.Hide();
    }

    private void OnFootnoteFlyoutOpening(object? sender, object e) => FootnoteLabelBox.Text = string.Empty;

    private void OnFootnoteLabelKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            ApplyFootnote();
        }
    }

    private void OnApplyFootnoteClick(object sender, RoutedEventArgs e) => ApplyFootnote();

    private void ApplyFootnote()
    {
        string trimmed = FootnoteLabelBox.Text.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }

        _ = Preview.RunEditorCommandAsync("insertFootnote", new JsonObject { ["label"] = trimmed });
        FootnoteButton.Flyout.Hide();
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

    /// <summary>
    /// Wraps the whole picker-and-open sequence in one try/catch — not just the
    /// <c>workspace.OpenAsync</c> call. A real gap this closes: <c>PickSingleFolderAsync</c>
    /// itself can throw (most commonly a COM exception when the picker's owning window isn't
    /// correctly identified, e.g. before <see cref="InitializeWithWindow"/> was added here, or
    /// when the app is running without package identity), and an uncaught exception from a
    /// fire-and-forget `_ = OpenFolderAsync()` call disappears silently instead of reporting
    /// through <see cref="Workspace.ReportOpenFailure"/> — which looks exactly like "the
    /// button does nothing" from the user's side, with nothing in the error banner to explain
    /// why.
    /// </summary>
    private async Task OpenFolderAsync()
    {
        try
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

            await workspace.OpenAsync(folder.Path);
        }
        catch (Exception exception)
        {
            workspace.ReportOpenFailure(exception);
        }
    }

    private void OnOpenFileClick(object sender, RoutedEventArgs e) => _ = OpenFileAsync();

    private async Task OpenFileAsync()
    {
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
            foreach (string extension in MarkdownFile.PickerExtensions)
            {
                picker.FileTypeFilter.Add(extension);
            }

            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

            StorageFile? file = await picker.PickSingleFileAsync();
            if (file is null)
            {
                return;
            }

            await workspace.OpenFileAsync(file.Path);
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

    // MARK: - Drag and drop

    /// <summary>Mirrors macOS's window-wide <c>.onDrop</c>: dropping a folder or a Markdown
    /// file anywhere over the window opens it, routed through the same
    /// <see cref="Workspace.OpenDroppedAsync"/> logic ContentView.swift's drop target and Dock
    /// icon / "Open With" routing both use. Wired to the outermost <c>Grid</c> in
    /// MainWindow.xaml, so it fires regardless of which part of the window the drop lands on.</summary>
    private void OnRootDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }

        e.AcceptedOperation = DataPackageOperation.Link;
        DropHighlight.Visibility = Visibility.Visible;
    }

    private void OnRootDragLeave(object sender, DragEventArgs e) => DropHighlight.Visibility = Visibility.Collapsed;

    private async void OnRootDrop(object sender, DragEventArgs e)
    {
        Microsoft.UI.Xaml.DragOperationDeferral deferral = e.GetDeferral();
        try
        {
            DropHighlight.Visibility = Visibility.Collapsed;

            if (!e.DataView.Contains(StandardDataFormats.StorageItems))
            {
                return;
            }

            IReadOnlyList<IStorageItem> items = await e.DataView.GetStorageItemsAsync();
            if (items.Count == 0)
            {
                return;
            }

            // Only the first dropped item is opened — same as ContentView.swift's
            // `providers.first`; dropping several items at once opens just one of them
            // rather than silently discarding the rest with no explanation.
            await workspace.OpenDroppedAsync(items[0].Path);
        }
        finally
        {
            deferral.Complete();
        }
    }
}
