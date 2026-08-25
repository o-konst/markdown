//
//  ChatView.xaml.cs
//  MarkdownWin
//
//  The assistant panel: a transcript plus a composer. Mirrors ChatView.swift. Every tool call
//  it makes goes through the same vault the editor writes through, so its edits are saved,
//  undoable, and show up in the file tree.
//
//  Hosted inside a ContentDialog (see MainWindow.ShowAssistantAsync) rather than a secondary
//  Window: macOS's chat panel is already a modal sheet that blocks the rest of the window
//  until dismissed, so there is no "keep chatting while editing" capability to preserve.
//

using System;
using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace MarkdownWin;

internal sealed partial class ChatView : UserControl
{
    /// <summary>Raised by the header's "Done" button; the owning dialog should hide itself.</summary>
    public event EventHandler? DoneRequested;

    public ChatViewModel ViewModel { get; }

    private bool isUpdatingComposer;

    private string? vaultRoot;

    /// <summary>Set by the host immediately before showing the dialog — never cached across opens.</summary>
    public string? VaultRoot
    {
        get => vaultRoot;
        set
        {
            vaultRoot = value;
            Composer.IsEnabled = vaultRoot is not null;
            EmptyStateDescription.Text = vaultRoot is null
                ? "Open a folder to give the assistant something to work with."
                : "It can search, read, and edit the notes in this folder. Every change is saved and can be undone.";
            UpdateSendEnabled();
        }
    }

    public ChatView()
    {
        InitializeComponent();

        // `DispatcherQueue` here is the instance property this UserControl inherits from
        // DependencyObject, not the Microsoft.UI.Dispatching.DispatcherQueue type — using it
        // directly avoids any ambiguity with that type name.
        ViewModel = new ChatViewModel(DispatcherQueue);
        Transcript.ItemsSource = ViewModel.Messages;
        ViewModel.Messages.CollectionChanged += OnMessagesChanged;
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;

        VaultRoot = null;
        UpdateEmptyStateVisibility();
    }

    private void OnDoneClick(object sender, RoutedEventArgs e) => DoneRequested?.Invoke(this, EventArgs.Empty);

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        UpdateEmptyStateVisibility();
        if (ViewModel.Messages.Count > 0)
        {
            Transcript.ScrollIntoView(ViewModel.Messages[^1]);
        }
    }

    private void UpdateEmptyStateVisibility()
    {
        bool empty = ViewModel.Messages.Count == 0;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        Transcript.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ChatViewModel.ErrorMessage):
                ErrorText.Text = ViewModel.ErrorMessage ?? string.Empty;
                ErrorText.Visibility = string.IsNullOrEmpty(ViewModel.ErrorMessage) ? Visibility.Collapsed : Visibility.Visible;
                break;

            case nameof(ChatViewModel.IsResponding):
            case nameof(ChatViewModel.Draft):
                UpdateSendEnabled();
                break;
        }
    }

    private void UpdateSendEnabled() =>
        SendButton.IsEnabled = vaultRoot is not null && !ViewModel.IsResponding && ViewModel.Draft.Trim().Length > 0;

    private void OnComposerTextChanged(object sender, TextChangedEventArgs e)
    {
        if (isUpdatingComposer)
        {
            return;
        }

        ViewModel.Draft = Composer.Text;
    }

    /// <summary>A plain Return submits, matching ChatView.swift's `.onSubmit` — there is no
    /// keyboard-driven way to insert a literal newline here, same as on macOS.</summary>
    private void OnComposerKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }

        e.Handled = true;
        Send();
    }

    private void OnSendClick(object sender, RoutedEventArgs e) => Send();

    private void Send()
    {
        if (!SendButton.IsEnabled || vaultRoot is not { } root)
        {
            return;
        }

        ViewModel.Send(root);

        isUpdatingComposer = true;
        Composer.Text = ViewModel.Draft;
        isUpdatingComposer = false;
    }
}
