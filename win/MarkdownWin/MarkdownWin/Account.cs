//
//  Account.cs
//  MarkdownWin
//
//  The signed-in person. Mirrors Account.swift.
//
//  There is no server behind this yet: signing in records a name and email locally so the
//  sidebar can show an account. Swapping in a real service means replacing LogIn and the
//  storage, not the views.
//

using System;
using System.Linq;

namespace MarkdownWin;

internal sealed class Account : ObservableBase
{
    private string fullName;
    private string email;

    public string FullName
    {
        get => fullName;
        private set => Set(ref fullName, value);
    }

    public string Email
    {
        get => email;
        private set => Set(ref email, value);
    }

    public bool IsLoggedIn => !string.IsNullOrEmpty(FullName);

    /// <summary>Initials for the sidebar's avatar, e.g. "Ada Lovelace" becomes "AL".</summary>
    public string Initials
    {
        get
        {
            string letters = string.Concat(FullName
                .Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Take(2)
                .Select(word => word[0]));
            return letters.Length == 0 ? "?" : letters.ToUpperInvariant();
        }
    }

    public Account()
    {
        fullName = AppSettings.AccountName ?? string.Empty;
        email = AppSettings.AccountEmail ?? string.Empty;
    }

    public void LogIn(string fullName, string email)
    {
        string name = fullName.Trim();
        if (name.Length == 0)
        {
            return;
        }

        FullName = name;
        Email = email.Trim();

        AppSettings.AccountName = FullName;
        AppSettings.AccountEmail = Email;

        Notify(nameof(IsLoggedIn));
        Notify(nameof(Initials));
    }

    public void LogOut()
    {
        FullName = string.Empty;
        Email = string.Empty;
        AppSettings.AccountName = null;
        AppSettings.AccountEmail = null;

        Notify(nameof(IsLoggedIn));
        Notify(nameof(Initials));
    }
}
