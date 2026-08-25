//
//  VaultWatcher.swift
//  Markdown
//
//  Watches the open folder so changes made outside the app show up in it.
//
//  This matters more than it used to: the bundled MCP server lets Claude Code and Claude
//  Desktop write into the same vault while the app is open, and an editor that silently
//  showed stale content would be worse than one with no integration at all.
//

import Foundation

#if os(macOS)
import CoreServices

nonisolated final class VaultWatcher {
    /// Coalescing window. Long enough that a burst of writes is one notification, short
    /// enough that a change feels immediate.
    private static let latency = 0.3

    private let onChange: @MainActor ([URL]) -> Void
    private var stream: FSEventStreamRef?

    init(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()

            // `UseCFTypes` makes this a CFArray of CFString.
            let raw = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.deliver(raw)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else {
            return
        }

        self.stream = stream
        // Delivering on the main queue keeps the hop to the UI trivial and ordered.
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        stopStream()
    }

    func stop() {
        stopStream()
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(_ paths: [String]) {
        // Committing rewrites `.git` constantly; those are our own bookkeeping, not notes.
        let interesting = paths
            .filter { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }
            .map { URL(filePath: $0) }
        guard !interesting.isEmpty else { return }

        // The stream is bound to the main queue, so this callback is already on it.
        MainActor.assumeIsolated {
            onChange(interesting)
        }
    }
}

#else

/// FSEvents is macOS-only; elsewhere the tree simply does not auto-refresh.
nonisolated final class VaultWatcher {
    init(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) {}
    func stop() {}
}

#endif
