//
//  ImageViewer.swift
//  Markdown
//
//  Read-only pan/zoom viewer for an image file selected in the sidebar.
//

import SwiftUI
import AppKit

/// An `NSClipView` that centers a document view smaller than its own bounds, rather than
/// pinning it to the origin (bottom-left, in AppKit's flipped-from-SwiftUI coordinate
/// space) — `NSClipView` does the latter by default, which is why zooming out otherwise
/// leaves the image stuck in the bottom-left corner instead of shrinking toward the center.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        if documentView.frame.width < rect.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if documentView.frame.height < rect.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Wraps `NSScrollView` + `NSImageView` rather than a hand-rolled SwiftUI
/// `MagnificationGesture` — `NSScrollView.allowsMagnification` gives native trackpad
/// pinch-to-zoom and scroll-to-pan for free.
struct ImageViewer: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8

        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = NSImageView()

        load(into: scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        load(into: scrollView, context: context)
    }

    private func load(into scrollView: NSScrollView, context: Context) {
        guard context.coordinator.loadedURL != url,
              let imageView = scrollView.documentView as? NSImageView
        else { return }
        context.coordinator.loadedURL = url

        let image = NSImage(contentsOf: url)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // The document view's frame must match the image's own pixel size for
        // NSScrollView's magnification/scrolling to behave correctly.
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
    }
}
