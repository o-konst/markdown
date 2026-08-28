//
//  PDFViewerView.swift
//  Markdown
//
//  Read-only viewer for a PDF file selected in the sidebar, with an optional page-thumbnail
//  panel on the right (toggled from ContentView's toolbar).
//

import SwiftUI
import PDFKit

/// `PDFView` is read-only by default (no editing API engaged) and already provides
/// pan/zoom/page navigation/scrolling natively — nothing custom needed beyond the wrapper.
/// `PDFThumbnailView` is PDFKit's own page-thumbnail browser (self-scrolling, like `PDFView`
/// itself — no enclosing `NSScrollView` needed), bound to the same `PDFView` instance so
/// clicking a thumbnail navigates it and the current page stays in sync.
struct PDFViewerView: NSViewRepresentable {
    let url: URL
    let isShowingThumbnails: Bool

    final class Coordinator {
        var loadedURL: URL?
        let pdfView = PDFView()
        let thumbnailView = PDFThumbnailView()
        var thumbnailWidthConstraint: NSLayoutConstraint?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let pdfView = context.coordinator.pdfView
        pdfView.autoScales = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let thumbnailView = context.coordinator.thumbnailView
        thumbnailView.pdfView = pdfView
        // No `layoutMode` on macOS (that's an iOS-only PDFThumbnailView property) — a
        // single column is how you get a vertical list here.
        thumbnailView.maximumNumberOfColumns = 1
        thumbnailView.thumbnailSize = NSSize(width: 90, height: 120)
        thumbnailView.backgroundColor = .controlBackgroundColor
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(pdfView)
        container.addSubview(thumbnailView)

        let widthConstraint = thumbnailView.widthAnchor.constraint(equalToConstant: thumbnailWidth)
        context.coordinator.thumbnailWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pdfView.trailingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),

            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            widthConstraint,
        ])

        load(into: context.coordinator)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        load(into: context.coordinator)
        context.coordinator.thumbnailWidthConstraint?.constant = thumbnailWidth
        context.coordinator.thumbnailView.isHidden = !isShowingThumbnails
    }

    private var thumbnailWidth: CGFloat { isShowingThumbnails ? 160 : 0 }

    private func load(into coordinator: Coordinator) {
        guard coordinator.loadedURL != url else { return }
        coordinator.loadedURL = url
        coordinator.pdfView.document = PDFDocument(url: url)
    }
}
