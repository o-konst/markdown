//
//  MarkdownWebView.xaml.cs
//  MarkdownWin
//
//  A WebView2 that hosts the Vue single page app embedded in the Rust core library.
//
//  Nothing is loaded from disk or the network: every request to `https://markdown-app.local/`
//  is answered from the bytes baked into `markdown_core`, and the JavaScript side asks the
//  same library to render Markdown over a bridge that mimics the WebKit message handler
//  the shared Vue app expects.
//

using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.Storage.Streams;
using Windows.System;

namespace MarkdownWin;

internal sealed partial class MarkdownWebView : UserControl
{
    private const string Host = "markdown-app.local";
    private const string Origin = $"https://{Host}";
    private const string IndexUrl = $"{Origin}/index.html";
    private const string MessageHandlerName = "markdownBridge";

    /// <summary>How long the host keeps offering the document to a web UI that has not mounted yet.</summary>
    private const int PushAttempts = 100;
    private static readonly TimeSpan PushRetryDelay = TimeSpan.FromMilliseconds(100);

    /// <summary>
    /// Recreates the WebKit message handler API the shared Vue app talks to
    /// (<c>window.webkit.messageHandlers.markdownBridge.postMessage</c>) on top of
    /// <c>chrome.webview</c>, keeping the web UI identical to the macOS build.
    /// </summary>
    private const string BridgeScript = """
        (function () {
          const pending = new Map();
          let nextId = 0;
          window.__markdownBridgeReply = function (id, result, error) {
            const entry = pending.get(id);
            if (!entry) { return; }
            pending.delete(id);
            if (error) { entry.reject(new Error(error)); } else { entry.resolve(result); }
          };
          const handler = {
            postMessage(body) {
              const id = ++nextId;
              return new Promise((resolve, reject) => {
                pending.set(id, { resolve, reject });
                window.chrome.webview.postMessage({ id: id, body: body });
              });
            }
          };
          window.webkit = window.webkit || {};
          window.webkit.messageHandlers = window.webkit.messageHandlers || {};
          window.webkit.messageHandlers.markdownBridge = handler;

          // The Vue app installs `__markdownHost.setDocument` when its components mount,
          // which can happen after the host already has a document. Owning the property
          // here lets the last pushed document be replayed the moment it subscribes,
          // instead of being dropped by the host's optional call.
          const host = (window.__markdownHost = window.__markdownHost || {});
          let listener = host.setDocument;
          let pending = null;
          Object.defineProperty(host, 'setDocument', {
            configurable: true,
            enumerable: true,
            get() { return listener; },
            set(value) {
              listener = value;
              if (value && pending !== null) {
                const text = pending;
                pending = null;
                value(text);
              }
            }
          });
          window.__markdownHostPush = function (text) {
            if (listener) { listener(text); } else { pending = text; }
          };
        })();
        """;

    private string text = string.Empty;
    private WebPreferences? preferences;
    private bool isLoaded;
    private bool isPushing;

    /// <summary>Raised when the shared web UI reports whether the open document has headings
    /// to navigate — forwarded from the `outlineState` bridge message.</summary>
    public event EventHandler<bool>? OutlineAvailabilityChanged;

    /// <summary>Raised once <c>WebView.CoreWebView2</c> exists, so callers can rely on
    /// <see cref="SetColorScheme"/> actually taking effect (e.g. applying the initial theme).</summary>
    public event EventHandler? CoreWebView2Ready;

    public MarkdownWebView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    /// <summary>Pushes a new document into the web UI, if it has finished loading.</summary>
    public void SetDocumentText(string newText)
    {
        if (newText == text)
        {
            return;
        }

        text = newText;
        _ = PushDocumentAsync();
    }

    /// <summary>
    /// Pushes updated rendering preferences into the web UI. Unlike <see cref="SetDocumentText"/>,
    /// this is a single best-effort call rather than a retry-until-mounted handshake: if it
    /// arrives before the Vue app mounts, the next `connect()` handshake (which now carries
    /// `preferences`) delivers the current snapshot anyway, so nothing is silently lost.
    /// </summary>
    public void SetPreferences(WebPreferences newPreferences)
    {
        if (preferences == newPreferences)
        {
            return;
        }

        preferences = newPreferences;
        if (!isLoaded || WebView.CoreWebView2 is null)
        {
            return;
        }

        string json = newPreferences.ToPayload().ToJsonString();
        _ = WebView.CoreWebView2.ExecuteScriptAsync(
            $"window.__markdownHost?.setPreferences?.({json});");
    }

    /// <summary>
    /// Applies <paramref name="theme"/> to the hosted web content's `prefers-color-scheme`.
    /// Setting `RequestedTheme` on the XAML tree changes native chrome but, unlike WKWebView
    /// on macOS, WebView2 does not pick that up automatically — this is the explicit bridge.
    /// </summary>
    public void SetColorScheme(ElementTheme theme)
    {
        if (WebView.CoreWebView2 is null)
        {
            return;
        }

        WebView.CoreWebView2.Profile.PreferredColorScheme = theme switch
        {
            ElementTheme.Dark => CoreWebView2PreferredColorScheme.Dark,
            ElementTheme.Light => CoreWebView2PreferredColorScheme.Light,
            _ => CoreWebView2PreferredColorScheme.Auto,
        };
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;

        if (!MarkdownCore.IsAvailable)
        {
            WebView.Visibility = Visibility.Collapsed;
            UnavailableMessage.Visibility = Visibility.Visible;
            return;
        }

        await WebView.EnsureCoreWebView2Async();
        CoreWebView2Ready?.Invoke(this, EventArgs.Empty);

        CoreWebView2 core = WebView.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.AddWebResourceRequestedFilter($"{Origin}/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += OnWebResourceRequested;
        core.WebMessageReceived += OnWebMessageReceived;
        core.NavigationCompleted += OnNavigationCompleted;
        core.NavigationStarting += OnNavigationStarting;
        core.NewWindowRequested += OnNewWindowRequested;
        await core.AddScriptToExecuteOnDocumentCreatedAsync(BridgeScript);

        core.Navigate(IndexUrl);
    }

    // MARK: - Serving the embedded Vue app

    private void OnWebResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        string path = new Uri(args.Request.Uri).AbsolutePath;
        WebAsset? asset = MarkdownCore.Asset(path);

        if (asset is null)
        {
            args.Response = sender.Environment.CreateWebResourceResponse(null, 404, "Not Found", string.Empty);
            return;
        }

        IRandomAccessStream stream = new MemoryStream(asset.Data).AsRandomAccessStream();
        string headers = string.Join(
            '\n',
            $"Content-Type: {asset.MimeType}",
            $"Content-Length: {asset.Data.Length}",
            "Cache-Control: no-store",
            "Access-Control-Allow-Origin: *");

        args.Response = sender.Environment.CreateWebResourceResponse(stream, 200, "OK", headers);
    }

    // MARK: - Calls from the Vue app into Rust

    private void OnWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        JsonNode? envelope;
        try
        {
            envelope = JsonNode.Parse(args.WebMessageAsJson);
        }
        catch (JsonException)
        {
            return;
        }

        if (envelope?["id"]?.GetValue<int>() is not int id)
        {
            return;
        }

        JsonNode? body = envelope["body"];
        string? method = body?["method"]?.GetValue<string>();

        switch (method)
        {
            case "connect":
                isLoaded = true;
                Reply(id, new JsonObject
                {
                    ["coreVersion"] = MarkdownCore.Version,
                    ["assetCount"] = MarkdownCore.AssetCount,
                    ["text"] = text,
                    ["preferences"] = preferences?.ToPayload(),
                });
                break;

            case "render":
                if (body?["markdown"]?.GetValue<string>() is not string markdown)
                {
                    Reply(id, null, "`render` requires a `markdown` string");
                    return;
                }

                Reply(id, JsonValue.Create(MarkdownCore.Render(markdown)));
                break;

            case "outlineState":
                if (body?["available"]?.GetValue<bool>() is bool available)
                {
                    OutlineAvailabilityChanged?.Invoke(this, available);
                }

                Reply(id, null);
                break;

            case null:
                Reply(id, null, "Malformed bridge message");
                break;

            default:
                Reply(id, null, $"Unknown bridge method '{method}'");
                break;
        }
    }

    private void Reply(int id, JsonNode? result, string? error = null)
    {
        string resultJson = result?.ToJsonString() ?? "null";
        string errorJson = error is null ? "null" : JsonSerializer.Serialize(error);
        _ = WebView.CoreWebView2.ExecuteScriptAsync(
            $"window.__markdownBridgeReply({id}, {resultJson}, {errorJson});");
    }

    // MARK: - Navigation

    private void OnNavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        isLoaded = true;
        _ = PushDocumentAsync();
    }

    /// <summary>Keeps the web view on the embedded app; links in the document open externally.</summary>
    private void OnNavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out Uri? uri) || uri.Host == Host)
        {
            return;
        }

        args.Cancel = true;
        _ = Launcher.LaunchUriAsync(uri);
    }

    private void OnNewWindowRequested(CoreWebView2 sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (Uri.TryCreate(args.Uri, UriKind.Absolute, out Uri? uri))
        {
            _ = Launcher.LaunchUriAsync(uri);
        }
    }

    /// <summary>
    /// Hands the current document to the web UI, retrying until it is accepted.
    /// Delivery goes through <c>__markdownHostPush</c>, installed by <see cref="BridgeScript"/>,
    /// which queues the document until the Vue app subscribes to it.
    /// </summary>
    private async Task PushDocumentAsync()
    {
        if (!isLoaded || isPushing || WebView.CoreWebView2 is null)
        {
            return;
        }

        isPushing = true;
        try
        {
            for (int attempt = 0; attempt < PushAttempts; attempt++)
            {
                string snapshot = text;
                string script = $$"""
                    (function () {
                      if (typeof window.__markdownHostPush !== 'function') { return false; }
                      window.__markdownHostPush({{JsonSerializer.Serialize(snapshot)}});
                      return true;
                    })();
                    """;

                string result = await WebView.CoreWebView2.ExecuteScriptAsync(script);

                if (result == "true")
                {
                    // A newer document may have arrived while the script was running.
                    if (snapshot == text)
                    {
                        return;
                    }

                    continue;
                }

                await Task.Delay(PushRetryDelay);
            }
        }
        finally
        {
            isPushing = false;
        }
    }
}
