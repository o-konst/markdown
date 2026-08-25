//
//  LoginDialog.xaml.cs
//  MarkdownWin
//
//  Sign-in dialog. Records the account locally; see Account.cs for why there is no network
//  call here. Mirrors LoginView.swift.
//

using Microsoft.UI.Xaml.Controls;

namespace MarkdownWin;

internal sealed partial class LoginDialog : ContentDialog
{
    private readonly Account account;

    public LoginDialog(Account account)
    {
        InitializeComponent();
        this.account = account;
    }

    private void OnFullNameChanged(object sender, TextChangedEventArgs e) =>
        IsPrimaryButtonEnabled = FullNameBox.Text.Trim().Length > 0;

    private void OnPrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args) =>
        account.LogIn(FullNameBox.Text, EmailBox.Text);
}
