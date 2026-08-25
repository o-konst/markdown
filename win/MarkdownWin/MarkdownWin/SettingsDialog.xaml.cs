//
//  SettingsDialog.xaml.cs
//  MarkdownWin
//
//  Modal dialog holding the rendering options. Each control writes straight to AppSettings,
//  which MainWindow reads back to push into the web UI. Mirrors SettingsView.swift.
//

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MarkdownWin;

internal sealed partial class SettingsDialog : ContentDialog
{
    /// <summary>Raised whenever any control here changes a persisted preference.</summary>
    public event EventHandler? PreferencesChanged;

    private bool isLoading = true;

    public SettingsDialog(bool isOutlineAvailable)
    {
        InitializeComponent();

        (string? key, CredentialStoreStatus status) = CredentialStore.TryGetApiKey();
        if (status == CredentialStoreStatus.Unavailable)
        {
            ApiKeyBox.IsEnabled = false;
            ApiKeyStatus.Text = "The API key could not be read from Windows Credential Manager. "
                + "This can happen when running the app unpackaged/from a debugger; a packaged install (MSIX) resolves it.";
            ApiKeyStatus.Visibility = Visibility.Visible;
        }
        else
        {
            ApiKeyBox.Password = key ?? string.Empty;
        }

        OutlineToggle.IsOn = AppSettings.OutlineVisible;
        OutlineToggle.IsEnabled = isOutlineAvailable;
        OutlineCaption.Visibility = isOutlineAvailable ? Visibility.Collapsed : Visibility.Visible;

        ThemeRadioButtons.SelectedIndex = (int)AppSettings.Appearance;
        WidthRadioButtons.SelectedIndex = AppSettings.ContentWidth == ContentWidth.Page ? 1 : 0;
        FontSizeBox.Value = AppSettings.FontSize;

        UpdateResetEnabled();
        isLoading = false;
    }

    private void OnApiKeyChanged(object sender, RoutedEventArgs e)
    {
        if (isLoading)
        {
            return;
        }

        CredentialStore.TrySetApiKey(ApiKeyBox.Password.Trim());
    }

    private void OnOutlineToggled(object sender, RoutedEventArgs e)
    {
        if (isLoading)
        {
            return;
        }

        AppSettings.OutlineVisible = OutlineToggle.IsOn;
        PreferencesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isLoading)
        {
            return;
        }

        AppSettings.Appearance = (AppAppearance)ThemeRadioButtons.SelectedIndex;
        UpdateResetEnabled();
        PreferencesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnWidthChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isLoading)
        {
            return;
        }

        AppSettings.ContentWidth = WidthRadioButtons.SelectedIndex == 1 ? ContentWidth.Page : ContentWidth.Full;
        UpdateResetEnabled();
        PreferencesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnFontSizeChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (isLoading || double.IsNaN(args.NewValue))
        {
            return;
        }

        AppSettings.FontSize = args.NewValue;
        UpdateResetEnabled();
        PreferencesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnResetClick(object sender, RoutedEventArgs e)
    {
        AppSettings.ResetToDefaults();

        isLoading = true;
        ThemeRadioButtons.SelectedIndex = (int)AppAppearance.System;
        WidthRadioButtons.SelectedIndex = 0;
        FontSizeBox.Value = FontSizeRange.Standard;
        isLoading = false;

        UpdateResetEnabled();
        PreferencesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void UpdateResetEnabled() => ResetButton.IsEnabled = !AppSettings.IsAtDefaults();
}
