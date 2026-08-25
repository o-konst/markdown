//
//  CredentialStore.cs
//  MarkdownWin
//
//  Stores the Anthropic API key in the Windows Credential Locker. Mirrors Keychain.swift:
//  kept out of ApplicationData.LocalSettings and out of the WebView2 JS context — a note can
//  contain arbitrary HTML/JS the webview renders, so anything reachable from JS is
//  exfiltratable by a crafted note. The key is only ever handed directly to Rust, via
//  AgentClient.Open's apiKey parameter.
//
//  PasswordVault requires the process to be running with a packaged (MSIX) identity. This
//  project's own build already documents friction around packaged activation on a network
//  drive (see MarkdownWin.csproj), so failures here are treated as a distinct, honest
//  "unavailable" state rather than crashing or looking identical to "no key set."
//

using System;
using Windows.Security.Credentials;

namespace MarkdownWin;

internal enum CredentialStoreStatus
{
    /// The call succeeded; Key may still be null/empty if nothing is stored.
    Ok,
    /// The credential locker itself could not be reached (e.g. no packaged identity).
    Unavailable,
}

internal static class CredentialStore
{
    private const string Resource = "MarkdownWin.anthropic-api-key";
    private const string UserName = "anthropic";

    /// Retrieve throws HRESULT 0x80070490 ("Element not found") when nothing is stored yet —
    /// that is the normal, everyday case and must not be treated as "unavailable."
    private const int ElementNotFoundHResult = unchecked((int)0x80070490);

    public static (string? Key, CredentialStoreStatus Status) TryGetApiKey()
    {
        try
        {
            var vault = new PasswordVault();
            PasswordCredential credential = vault.Retrieve(Resource, UserName);
            credential.RetrievePassword();
            return (credential.Password, CredentialStoreStatus.Ok);
        }
        catch (Exception error) when (error.HResult == ElementNotFoundHResult)
        {
            return (null, CredentialStoreStatus.Ok);
        }
        catch (Exception)
        {
            return (null, CredentialStoreStatus.Unavailable);
        }
    }

    public static string? GetApiKey() => TryGetApiKey().Key;

    /// <summary>An empty key clears the stored one. Returns false if the credential locker is unavailable.</summary>
    public static bool TrySetApiKey(string key)
    {
        try
        {
            var vault = new PasswordVault();
            try
            {
                vault.Remove(vault.Retrieve(Resource, UserName));
            }
            catch (Exception error) when (error.HResult == ElementNotFoundHResult)
            {
                // Nothing stored yet; fine.
            }

            if (!string.IsNullOrEmpty(key))
            {
                vault.Add(new PasswordCredential(Resource, UserName, key));
            }

            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
