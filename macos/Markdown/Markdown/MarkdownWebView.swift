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

    func makeCoordinator() -> WebPreviewCoordinator {
        WebPreviewCoordinator(
            text: text,
            preferences: preferences,
            onOutlineAvailabilityChange: onOutlineAvailabilityChange
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
    private var isLoaded = false
    private weak var webView: WKWebView?

    init(
        text: String,
        preferences: WebPreferences,
        onOutlineAvailabilityChange: @escaping (Bool) -> Void
    ) {
        self.text = text
        self.preferences = preferences
        self.onOutlineAvailabilityChange = onOutlineAvailabilityChange
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
