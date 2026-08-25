//
//  MarkdownWebView.swift
//  Markdown
//
//  A WKWebView that hosts the Vue single page app embedded in the Rust core library.
//
//  Nothing is loaded from disk or the network: a custom URL scheme handler answers every
//  request straight from the bytes baked into `libmarkdown_core.a`, and the JavaScript
//  side asks the same library to render Markdown over a script message handler.
//

import SwiftUI
import WebKit

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

enum WebUI {
    /// Custom scheme served entirely from the embedded assets.
    static let scheme = "markdown-app"
    static let host = "local"
    static let messageHandlerName = "markdownBridge"

    static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!
}

/// Renders `text` with the Rust backend and displays the result in the embedded web UI.
struct MarkdownWebView {
    var text: String

    /// Rendering options for the web UI. Pushed on every change.
    var preferences: WebPreferences

    /// Called when the web UI reports whether the document has an outline at all.
    var onOutlineAvailabilityChange: (Bool) -> Void

    /// Called when the WYSIWYG editor reports an edit, so it flows into `Workspace.text`
    /// and through the existing autosave/vault-write path unchanged. See the
    /// echo-suppression note on `userContentController(_:didReceive:replyHandler:)` below
    /// for why this must not simply re-push the same text back into the web view.
    var onDocumentEdit: (String) -> Void

    func makeCoordinator() -> WebPreviewCoordinator {
        WebPreviewCoordinator(
            text: text,
            preferences: preferences,
            onOutlineAvailabilityChange: onOutlineAvailabilityChange,
            onDocumentEdit: onDocumentEdit
        )
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension MarkdownWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOutlineAvailabilityChange = onOutlineAvailabilityChange
        context.coordinator.onDocumentEdit = onDocumentEdit
        context.coordinator.setDocumentText(text)
        context.coordinator.setPreferences(preferences)
    }
}

#else

extension MarkdownWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOutlineAvailabilityChange = onOutlineAvailabilityChange
        context.coordinator.onDocumentEdit = onDocumentEdit
        context.coordinator.setDocumentText(text)
        context.coordinator.setPreferences(preferences)
    }
}

#endif

/// Owns the web view and both directions of the bridge:
/// asset requests coming from WebKit, and `connect`/`render` calls coming from the Vue app.
@MainActor
final class WebPreviewCoordinator: NSObject {
    private var text: String
    private var preferences: WebPreferences
    var onOutlineAvailabilityChange: (Bool) -> Void
    var onDocumentEdit: (String) -> Void
    private var isLoaded = false
    private weak var webView: WKWebView?

    init(
        text: String,
        preferences: WebPreferences,
        onOutlineAvailabilityChange: @escaping (Bool) -> Void,
        onDocumentEdit: @escaping (String) -> Void
    ) {
        self.text = text
        self.preferences = preferences
        self.onOutlineAvailabilityChange = onOutlineAvailabilityChange
        self.onDocumentEdit = onDocumentEdit
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(self, forURLScheme: WebUI.scheme)
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: WebUI.messageHandlerName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: WebUI.indexURL))

        self.webView = webView
        return webView
    }

    /// Pushes a new document into the web UI, if it has finished loading.
    func setDocumentText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        pushDocument()
    }

    /// Pushes the rendering options into the web UI, if they changed.
    func setPreferences(_ newValue: WebPreferences) {
        guard newValue != preferences else { return }
        preferences = newValue
        pushPreferences()
    }

    private func pushPreferences() {
        guard isLoaded, let webView else { return }
        webView.callAsyncJavaScript(
            "window.__markdownHost?.setPreferences?.(preferences)",
            arguments: ["preferences": preferences.payload],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                NSLog("Markdown: failed to push preferences into the web view: \(error)")
            }
        }
    }

    private func pushDocument() {
        guard isLoaded, let webView else { return }
        webView.callAsyncJavaScript(
            "window.__markdownHost?.setDocument(text)",
            arguments: ["text": text],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                NSLog("Markdown: failed to push document into the web view: \(error)")
            }
        }
    }

    /// Asks the WYSIWYG editor to report its current text immediately, cancelling any
    /// pending debounce — the opposite direction of `documentEdit`, native calling into
    /// JS. `Workspace` does not currently call this before switching the open file (see
    /// the design note in `.claude/docs/live-preview-editing-research.md` and this
    /// phase's report): `Workspace.selectedFile`'s flush-on-switch is a synchronous
    /// property observer, and this call is inherently asynchronous, so wiring the two
    /// together needs a small architectural change to `Workspace` beyond this phase's
    /// scope, not just a call here. Implemented and ready to use once that lands.
    func flushPendingEdit() async -> String? {
        guard isLoaded, let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__markdownHost?.flushPendingEdit?.();",
                in: nil,
                in: .page
            )
            return result as? String
        } catch {
            NSLog("Markdown: failed to flush the WYSIWYG editor's pending edit: \(error)")
            return nil
        }
    }
}

// MARK: - Serving the embedded Vue app

extension WebPreviewCoordinator: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let asset = MarkdownCore.asset(forPath: url.path)
        else {
            urlSchemeTask.didFailWithError(
                URLError(.fileDoesNotExist, userInfo: [
                    NSURLErrorFailingURLErrorKey: urlSchemeTask.request.url as Any
                ])
            )
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": asset.mimeType,
                "Content-Length": String(asset.data.count),
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*",
            ]
        )!

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(asset.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Every task is answered synchronously in `start`, so there is nothing to cancel.
    }
}

// MARK: - Calls from the Vue app into Rust

extension WebPreviewCoordinator: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String
        else {
            replyHandler(nil, "Malformed bridge message")
            return
        }

        switch method {
        case "connect":
            isLoaded = true
            replyHandler([
                "coreVersion": MarkdownCore.version,
                "assetCount": MarkdownCore.assetCount,
                "text": text,
                // Sent with the handshake so the UI never flashes into the wrong state.
                "preferences": preferences.payload,
            ], nil)

        case "render":
            guard let markdown = body["markdown"] as? String else {
                replyHandler(nil, "`render` requires a `markdown` string")
                return
            }
            replyHandler(MarkdownCore.render(markdown), nil)

        case "outlineState":
            guard let available = body["available"] as? Bool else {
                replyHandler(nil, "`outlineState` requires an `available` boolean")
                return
            }
            onOutlineAvailabilityChange(available)
            replyHandler(nil, nil)

        case "documentEdit":
            guard let newText = body["text"] as? String else {
                replyHandler(nil, "`documentEdit` requires a `text` string")
                return
            }
            // Echo suppression: `setDocumentText`'s `guard newText != text else { return }`
            // is what stops this edit from being pushed straight back down into the web
            // view and clobbering the WYSIWYG editor's cursor/selection — but only if
            // `text` already matches by the time SwiftUI's next update pass calls
            // `setDocumentText(workspace.text)`. Setting it here, before calling
            // `onDocumentEdit`, is what makes that true. Do not reorder these two lines.
            text = newText
            onDocumentEdit(newText)
            replyHandler(nil, nil)

        default:
            replyHandler(nil, "Unknown bridge method '\(method)'")
        }
    }
}

// MARK: - Navigation

extension WebPreviewCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        pushDocument()
        pushPreferences()
    }

    /// Keeps the web view on the embedded app; links in the document open externally.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if url.scheme == WebUI.scheme || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            openExternally(url)
        }
        decisionHandler(.cancel)
    }

    private func openExternally(_ url: URL) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
