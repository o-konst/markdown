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

    /// Called on every update with a closure that flushes the WYSIWYG editor's pending edit
    /// (see `WebPreviewCoordinator.flushPendingEdit()`). `Workspace` has no reference to this
    /// coordinator — or to `WKWebView`/SwiftUI at all — so this is how it gets one, matching
    /// `Workspace`'s existing style of taking dependencies (vault, watcher) as plain closures
    /// rather than concrete UI-framework types.
    var registerFlushPendingEdit: (@escaping () async -> String?) -> Void

    /// Called when the web UI reports a new `EditorToolbarState` (active marks, heading
    /// level, mode, ...), so a native formatting toolbar can render itself.
    var onEditorStateChange: (EditorToolbarState) -> Void

    /// Called on every update with a closure that runs a formatting command
    /// (`WebPreviewCoordinator.runEditorCommand(_:payload:)`) — the reverse direction of
    /// `onDocumentEdit`. Unlike `registerFlushPendingEdit`, this one is consumed directly by
    /// `ContentView`'s own toolbar rather than by `Workspace`, so it's registered the same
    /// way but for a purely UI-local concern.
    var registerRunEditorCommand: (@escaping (String, [String: Any]?) async -> Bool) -> Void

    func makeCoordinator() -> WebPreviewCoordinator {
        WebPreviewCoordinator(
            text: text,
            preferences: preferences,
            onOutlineAvailabilityChange: onOutlineAvailabilityChange,
            onDocumentEdit: onDocumentEdit,
            onEditorStateChange: onEditorStateChange
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
        context.coordinator.onEditorStateChange = onEditorStateChange
        context.coordinator.setDocumentText(text)
        context.coordinator.setPreferences(preferences)
        registerFlushPendingEdit { [coordinator = context.coordinator] in
            await coordinator.flushPendingEdit()
        }
        registerRunEditorCommand { [coordinator = context.coordinator] command, payload in
            await coordinator.runEditorCommand(command, payload: payload)
        }
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
        context.coordinator.onEditorStateChange = onEditorStateChange
        context.coordinator.setDocumentText(text)
        context.coordinator.setPreferences(preferences)
        registerFlushPendingEdit { [coordinator = context.coordinator] in
            await coordinator.flushPendingEdit()
        }
        registerRunEditorCommand { [coordinator = context.coordinator] command, payload in
            await coordinator.runEditorCommand(command, payload: payload)
        }
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
    var onEditorStateChange: (EditorToolbarState) -> Void
    private var isLoaded = false
    private weak var webView: WKWebView?

    init(
        text: String,
        preferences: WebPreferences,
        onOutlineAvailabilityChange: @escaping (Bool) -> Void,
        onDocumentEdit: @escaping (String) -> Void,
        onEditorStateChange: @escaping (EditorToolbarState) -> Void
    ) {
        self.text = text
        self.preferences = preferences
        self.onOutlineAvailabilityChange = onOutlineAvailabilityChange
        self.onDocumentEdit = onDocumentEdit
        self.onEditorStateChange = onEditorStateChange
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
    /// JS. Wired into every `Workspace` flush point (`flushPendingSaveAsync`) so switching
    /// files can't silently drop trailing keystrokes still sitting in the editor's own
    /// debounce.
    ///
    /// `callAsyncJavaScript` has no `async throws`-returning overload in this SDK — its
    /// only form is completion-handler-based (`(Result<Any, Error>) -> Void`), same as
    /// `pushDocument()`/`pushPreferences()` above. An earlier version of this method wrote
    /// `try await webView.callAsyncJavaScript(...)` directly, which compiled but silently
    /// resolved to a *different*, `Void`-returning overload — caught by the build's own
    /// warnings (`result` inferred as `()`, "cast from `()` to `String` always fails"),
    /// not by any runtime symptom. Bridged through `withCheckedContinuation` instead.
    func flushPendingEdit() async -> String? {
        guard isLoaded, let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(
                "return await window.__markdownHost?.flushPendingEdit?.();",
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value as? String)
                case .failure(let error):
                    NSLog("Markdown: failed to flush the WYSIWYG editor's pending edit: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Runs a formatting command (`toggleBold`, `setHeading`, `setMode`, ...) against the
    /// live WYSIWYG editor — native calling into JS, the same direction and the same
    /// `callAsyncJavaScript` + `withCheckedContinuation` bridging as `flushPendingEdit()`
    /// above (that fix is the template here: this SDK's `callAsyncJavaScript` has no
    /// `async throws`-returning overload, only a completion-handler one). `payload` is
    /// always passed as a dictionary, `[:]` when the command takes none — `toggleLink`
    /// with an empty payload correctly reads on the JS side as "no href", i.e. remove the
    /// link, so there is no need to distinguish "no payload" from "empty payload" here.
    func runEditorCommand(_ command: String, payload: [String: Any]? = nil) async -> Bool {
        guard isLoaded, let webView else { return false }
        return await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(
                "return window.__markdownHost?.runEditorCommand?.(command, payload) ?? false;",
                arguments: ["command": command, "payload": payload ?? [:]],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value as? Bool ?? false)
                case .failure(let error):
                    NSLog("Markdown: failed to run editor command '\(command)': \(error)")
                    continuation.resume(returning: false)
                }
            }
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

        case "editorStateChanged":
            guard let stateBody = body["state"] as? [String: Any],
                  let state = EditorToolbarState(body: stateBody)
            else {
                replyHandler(nil, "`editorStateChanged` requires a valid `state` object")
                return
            }
            onEditorStateChange(state)
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
