//
//  WelcomeView.swift
//  Markdown
//
//  Shown in the detail pane when nothing is open (`Workspace.isEmpty`) — every launch
//  starts here, since no vault is auto-reopened. Surfaces the Recent Vaults list (see
//  RecentVaults.swift) so reopening something is one click instead of a picker round-trip.
//

import AppKit
import SwiftUI

struct WelcomeView: View {
    let workspace: Workspace
    let openFolder: () -> Void
    let openFile: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Markdown")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Open a folder or file to get started.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Open Folder…", action: openFolder)
                Button("Open File…", action: openFile)
            }
            .buttonStyle(.borderedProminent)

            if !workspace.recentVaults.entries.isEmpty {
                recentList
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(workspace.recentVaults.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider()
                    }
                    RecentVaultRow(entry: entry) {
                        Task { @MainActor in await workspace.openRecent(entry) }
                    } remove: {
                        workspace.recentVaults.remove(entry)
                    }
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 420)
    }
}

private struct RecentVaultRow: View {
    let entry: RecentVaultEntry
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .lineLimit(1)
                    Text(abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from Recent", action: remove)
        }
    }

    private var abbreviatedPath: String {
        (entry.path as NSString).abbreviatingWithTildeInPath
    }
}

#Preview {
    WelcomeView(workspace: Workspace(), openFolder: {}, openFile: {})
}
